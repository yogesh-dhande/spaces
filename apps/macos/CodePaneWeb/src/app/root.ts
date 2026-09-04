import { createBridge } from "../bridge";
import {
  CodePaneAgentsChangedEvent,
  CodePaneAgentStartStatusEvent,
  CodePaneDiffEditorState,
  CodePaneEditorUIState,
  CodePaneInitPayload,
  CodePaneSetModeEvent,
  CodePaneThemeChangedEvent,
  DiffFileEntry,
  PendingAgentLaunch,
  SpacesBridgeError,
  WorkspaceDiffManifestChunkResult,
  WorkspaceFileReadResult,
  WorkspaceRevisionFileReadResult,
  type DiffScope,
} from "../bridge/types";
import { CommentsController, CommentsToolbarState } from "./commentsController";
import { DiffView, type PreparedDiffEdit } from "./diffView";
import { EditorSidebar } from "./editorSidebar";
import { EditorView } from "./editorView";
import { diff3MergeLines } from "./editorView";
import { renderFileList, updateFileListRow } from "./fileList";
import { attachFileListDivider } from "./fileListDivider";
import { QuickOpen } from "./quickOpen";
import { RefSearchDialog } from "./refSearchDialog";
import { afterBrowserPaint, aggregateContentUnits, browserPaint } from "./renderMetrics";
import { selectDefaultAgentId } from "./reviewComments";
import { CodePaneAction, CodePaneState, codePaneReducer, initialState } from "./state";
import { renderToolbar } from "./toolbar";
import { WorkspaceFileListCache } from "./workspaceFileListCache";

/** Most-recently-opened first, deduped, capped here — see `CodePaneEditorUIState.recentPaths`'s
 *  doc comment for the contract every successful open (⌘P overlay, Files tree, Changes list in
 *  editor mode) must satisfy. */
const RECENT_PATHS_CAP = 12;
/** Large dirty buffers belong in a recovery snapshot, but WK structured-cloning them for every
 * keystroke does not. The collector below still has the latest live state at teardown. */
const WORKSPACE_STATE_DEBOUNCE_MS = 250;
const AGENT_RESUME_RETRY_FLOOR_MS = 1000;
const AGENT_RESUME_RETRY_CAP_MS = 30000;

const INIT_EVENT = "spaces:init";
const THEME_EVENT = "spaces:theme";
const AGENTS_EVENT = "spaces:agents";
const AGENT_START_STATUS_EVENT = "spaces:agentStartStatus";
const SET_MODE_EVENT = "spaces:setMode";

/** Keep performance milestones tied to the comparison that produced them.  The native E2E
 * harness uses this to distinguish a selected scope from an older refresh still draining. */
function renderMetricScope(scope: DiffScope): string {
  return scope.kind === "ref" ? `ref:${scope.refName}` : scope.kind;
}

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

  let state: CodePaneState = initialState(initPayload.workspaceState.mode, initPayload.workspaceState.scope);
  state = { ...state, layout: initPayload.workspaceState.diffLayout, editorPath: initPayload.workspaceState.editorState?.path };
  let files: DiffFileEntry[] = [];
  let diffLoaded = false;
  // Editor mode's sidebar-toggle/recent-files state lives at the pane boundary alongside the other
  // workspace-local recovery fields, rather than inside EditorView.
  let editorUIState: CodePaneEditorUIState = {
    sidebarMode: initPayload.workspaceState.editorSidebarMode,
    recentPaths: initPayload.workspaceState.editorRecentPaths,
  };
  let fileTreeExpandedPaths = initPayload.workspaceState.fileTreeExpandedPaths;
  let diffSelectedPath = initPayload.workspaceState.diffSelectedPath;
  let diffTreeExpandedPaths = initPayload.workspaceState.diffTreeExpandedPaths;
  let diffTreeSelectedPath = initPayload.workspaceState.diffTreeSelectedPath ?? diffSelectedPath;
  // An inactive CodeView is detached from the DOM during a mode switch, so it cannot be sampled
  // reliably after `renderBody`. Preserve its logical location until that view becomes visible and
  // supplies a newer one.
  let durableEditorScrollLine = initPayload.workspaceState.editorScrollLine ?? null;
  let durableEditorFocusedLine = initPayload.workspaceState.editorFocusedLine ?? null;
  let diffEditorState: CodePaneDiffEditorState | undefined = initPayload.workspaceState.diffEditorState ?? undefined;
  // A hibernated Last Commit editor cannot be rendered until its streamed file metadata supplies
  // the immutable revision required to prove the worktree still matches the reviewed commit.
  let pendingLastCommitDiffEditorRestore = state.scope.kind === "lastCommit" && diffEditorState !== undefined;
  // Only a transition from another comparison needs a fresh old side. A pane that was already in
  // Last Commit persists its stable review baseline across hibernation, while ref/base → Last
  // Commit must derive the different historical side from the newly completed commit patch.
  let pendingLastCommitComparisonRebuild = false;
  // A persisted Last Commit draft is deliberately not trusted on its own: only this page's
  // immutable revision read proves that its saved CAS target still names the reviewed checkout.
  // This lets a failed refresh restore an editor that was already verified in this page, while an
  // entering/restored draft remains safely recoverable through Uncommitted instead.
  let lastCommitDiffEditorVerified = false;
  // Every comparison scope owns a distinct patch left side. A live inline editor waits for its
  // replacement patch before it can be rendered again, preserving its dirty right-side buffer.
  let pendingScopeTransitionDiffEditorRestore = false;
  /** Changes only when a distinct inline editor owns the surface; typing deliberately preserves it. */
  let diffEditSessionToken = diffEditorState === undefined ? 0 : 1;
  /** A stale save must not block the editor that replaced its session. */
  let diffEditSaveInFlightSession: number | undefined;
  /** A signature read can prove an in-flight save landed before its RPC settles. */
  let diffEditDiskConfirmedSave: { session: number; contentGeneration: number } | undefined;
  let diffEditRequestToken = 0;
  /** Advances only for user typing in the inline diff editor. A successful CAS write adopts its
   * returned baseline only when this value still matches the content it sent. */
  let diffEditContentGeneration = 0;
  /** Only the newest disk reconciliation may apply; typing keeps the same edit session and is
   * reconciled against the latest buffer when that read completes. */
  let diffEditReconcileToken = 0;
  let workspaceStatePushTimer: ReturnType<typeof setTimeout> | undefined;
  let initialDiffScrollRestored = false;
  let pendingAgentLaunch: PendingAgentLaunch | undefined = initPayload.workspaceState.pendingAgentLaunch ?? undefined;
  // Set synchronously when the Start Agent form submits and cleared only when that exact bridge
  // request settles. The native response is the source of the durable session id, so this transient
  // guard deliberately stays local while the request is in flight and prevents a second launch from
  // being submitted after the dialog is cancelled and reopened.
  let startAgentRequestInFlight = false;
  let startAgentRequestCommand: string | undefined;
  let agentResumeRetryTimer: ReturnType<typeof setTimeout> | undefined;
  let agentResumeDeadlineTimer: ReturnType<typeof setTimeout> | undefined;
  let agentResumeRetryFailures = 0;
  /** Once the original readiness window has elapsed, native gets one exact-session reconciliation
   * attempt. It is terminal: retries must not create another deadline or race a late status event. */
  let agentResumeFinalReconciliation = false;
  let agentResumeGeneration = 0;
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
  /** The single daemon-owned transfer currently being read. A refresh generation that supersedes it
   * releases the snapshot immediately instead of waiting for the daemon's TTL. */
  let activePatchTransfer:
    | { scope: import("../bridge/types").DiffScope; manifestID: string; path: string; byteOffset: number; transferID: string }
    | undefined;
  /** The manifest owns the daemon's frozen enumeration/base/signature plan. Patch bytes are still
   * generated when a file begins streaming. The lease is released after terminal streaming or as
   * soon as a newer generation supersedes it, independent of a per-file chunk cancellation. */
  let activeManifest: { scope: import("../bridge/types").DiffScope; manifestID: string; token: number } | undefined;
  /** A queued sidebar selection moves to the head of the not-yet-started work without interrupting
   * the file already streaming. */
  let prioritizedPatchPath: string | undefined;
  // A configured base is stored as a short branch name, while a workspace may only have its
  // remote-tracking counterpart (for example `origin/main`). The preset resolves that spelling
  // lazily on activation so a diff-only pane does not pay for a ref listing at startup. This token
  // also prevents a slow listing reply from overriding a later user-selected scope.
  let configuredBaseSelectionToken = 0;
  let configuredBaseRefName: string | undefined;

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
  diffAreaEl.tabIndex = -1;
  diffAreaEl.style.position = "relative"; // hosts the comments controller's absolutely-positioned error banner

  const editorContainerEl = document.createElement("div");
  editorContainerEl.className = "diff-area";
  editorContainerEl.tabIndex = -1;

  function pendingStartingAgentSessionId(): string | undefined {
    return pendingAgentLaunch?.status === "starting" ? pendingAgentLaunch.sessionId : undefined;
  }

  // Seeded synchronously to match `CommentsController`'s own constructor logic exactly (see
  // `selectDefaultAgentId`), so the toolbar's very first paint already reflects the real
  // auto-default rather than an `undefined` placeholder that only self-corrects once the
  // controller's first `onToolbarStateChange` callback fires.
  let lastCommentsToolbarState: CommentsToolbarState = {
    agents: initPayload.agents,
    selectedAgentId: selectDefaultAgentId(
      initPayload.agents,
      initPayload.agents.find((agent) => agent.sessionId === initPayload.workspaceState.selectedAgentSessionId)?.id,
      pendingStartingAgentSessionId(),
    ),
    draftCount: 0,
  };
  let agentStarting = pendingAgentLaunch?.status === "starting";

  const comments = new CommentsController(
    bridge,
    initPayload.agents,
    {
      onToolbarStateChange: (commentsState, options) => {
        lastCommentsToolbarState = commentsState;
        toolbar.update(buildToolbarState());
        if (options?.liveText) scheduleWorkspaceStatePush();
        else pushWorkspaceState();
      },
    },
    initPayload.workspaceState.selectedAgentSessionId,
    pendingStartingAgentSessionId(),
  );
  const diffView = new DiffView(diffAreaEl, state.layout, {
    ...comments.hooks,
    onRequestEdit: (path) => void beginDiffEdit(path),
    onDiffEditChange: (path, content) => {
      if (diffEditorState?.path !== path) return;
      // This callback can only come from Pierre's already-open editor, whose Last Commit entry
      // path passed `readDiffEditBaseline` before `activatePreparedDiffEdit` installed it. Keep
      // that proof attached to the live session across a hibernated patch retry.
      if (state.scope.kind === "lastCommit") lastCommitDiffEditorVerified = true;
      diffEditContentGeneration += 1;
      diffEditorState = { ...diffEditorState, content, dirty: true, conflict: false, conflictBaseSHA256: null };
      scheduleWorkspaceStatePush();
    },
    onSaveDiffEdit: (path) => void saveDiffEdit(path, diffEditorState?.baseSHA256),
    onCancelDiffEdit: (path) => cancelDiffEdit(path),
    onResolveDiffEdit: (path, action) => void resolveDiffEdit(path, action),
    onPositionChange: () => scheduleWorkspaceStatePush(),
    onDiscardAndOpenDiffEdit: (currentPath, nextPath) => void discardAndOpenDiffEdit(currentPath, nextPath),
  });
  // Seed the inactive diff view before any initialization await. A pane can be torn down while it
  // starts in Editor mode, or while its first diff manifest is still loading; the hibernation
  // collector must retain the saved logical location even though no diff line is mounted yet.
  diffView.restorePosition(
    initPayload.workspaceState.diffSelectedPath,
    initPayload.workspaceState.diffScrollLine,
    initPayload.workspaceState.diffScrollSide,
    initPayload.workspaceState.diffFocusedPath,
    initPayload.workspaceState.diffFocusedLine,
    initPayload.workspaceState.diffFocusedSide,
  );
  comments.attachDiffView(diffView);
  comments.mount(diffAreaEl);
  // The initial list is workspace-scoped rather than patch-scoped. Start it as soon as the first
  // manifest has given CommentsController queued file identities, so drafts/tray do not wait for a
  // large diff's final patch. Every later call returns this one promise.
  let initialCommentsLoad: Promise<void> | undefined;
  function loadInitialComments(): Promise<void> {
    initialCommentsLoad ??= comments.loadInitial();
    return initialCommentsLoad;
  }
  const editorView = new EditorView(editorContainerEl, bridge, {
    // The success-only seam (see `EditorViewCallbacks.onFileOpened`'s doc comment): fires only once
    // `loadFile()` actually replaces the buffer with `path`'s content, so a refused open (the
    // discard-consent banner) or a failed read never records a recent or moves the Files tree's
    // selection (Finding C) — `openInEditor` below stops doing either of those itself. Restoring a
    // hibernated buffer never fires this either (see `EditorView.restoreState`'s doc comment), so a
    // pane that reopens straight into its last file doesn't re-record it as a fresh open.
    onFileOpened: (path) => {
      state = codePaneReducer(state, { type: "openFile", path });
      durableEditorScrollLine = null;
      durableEditorFocusedLine = null;
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
    onStateChanged: () => scheduleWorkspaceStatePush(),
    onStateTransition: () => pushWorkspaceState(),
  });

  // Scroll offsets are not durable under a virtualizer; source lines are. Capture the current
  // logical line after scroll/focus settles, but coalesce the complete recovery document so a
  // trackpad scroll never repeatedly structured-clones a dirty editor buffer.
  diffAreaEl.addEventListener("scroll", () => scheduleWorkspaceStatePush(), true);
  editorContainerEl.addEventListener("scroll", () => scheduleWorkspaceStatePush(), true);
  editorContainerEl.addEventListener("focusin", () => scheduleWorkspaceStatePush(), true);

  // Shared by Editor mode's Files tree (`editorSidebar`) and the ⌘P quick-open overlay
  // (`quickOpen`) — see WorkspaceFileListCache's doc comment for why one lazily-fetched instance is
  // shared rather than each owning its own.
  const fileListCache = new WorkspaceFileListCache(bridge);

  const editorSidebar = new EditorSidebar(
    changesListEl,
    fileListCache,
    // `workspaceState.editorState?.path` (not anything EditorView reports back) is the source for the
    // initial selected row: it's available synchronously at construction time, before
    // `editorView.restoreState` below has even run.
    {
      sidebarMode: editorUIState.sidebarMode,
      selectedPath: initPayload.workspaceState.fileTreeSelectedPath ?? initPayload.workspaceState.editorState?.path ?? undefined,
      expandedPaths: fileTreeExpandedPaths,
    },
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
      onTreeStateChange: (treeState) => {
        fileTreeExpandedPaths = [...treeState.expandedPaths];
        pushWorkspaceState();
      },
    },
  );

  const quickOpen = new QuickOpen(pane, fileListCache, () => editorUIState.recentPaths, {
    getMode: () => state.mode,
    isInDiff: (path) => files.some((file) => file.path === path),
    // Match the Changes-sidebar path: it persists selection, promotes a queued patch, then
    // reveals it. A bare `scrollToFile` leaves the selected file behind the stream queue. A
    // Quick Open hit additionally remains a recent-file navigation, unlike a sidebar click.
    openInDiff: (path) => {
      changesOnSelect(path);
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
    pushWorkspaceState();
  }

  /** Captures both code surfaces while they are still attached. `renderBody` detaches the outgoing
   * one on a mode switch, at which point its virtualized geometry is no longer observable. */
  function captureViewPositions(): void {
    // Sampling happens before every snapshot and explicitly before `renderBody` below. A detached
    // inactive CodeView has no trustworthy geometry, so never let that null overwrite its last
    // observed source line.
    diffView.durableScrollPosition();
    const visibleEditorLine = editorView.visibleLine();
    if (visibleEditorLine !== null) durableEditorScrollLine = visibleEditorLine;
    const focusedEditorLine = editorView.focusedLineNumber();
    if (focusedEditorLine !== null) durableEditorFocusedLine = focusedEditorLine;
  }

  /** Produces the one host-persisted workspace document. It is intentionally assembled at the
   * pane boundary: EditorView and CommentsController can each change independently, but recovery
   * must never capture one surface from before and the other from after a workspace switch. */
  function workspaceStateSnapshot(tearingDown = false) {
    // Routine pushes must be observational: typing elsewhere in the pane must never cancel a
    // comment-list retry. The host's synchronous teardown pull is the one lifecycle boundary that
    // stops controller-owned timers before this page disappears.
    const pending = tearingDown ? comments.collectStateForFlush() : comments.snapshotPendingState();
    captureViewPositions();
    const durableDiffPosition = diffView.durableScrollPosition();
    const focusedDiffPosition = diffView.focusedPosition();
    return {
      mode: state.mode,
      scope: state.scope,
      diffLayout: state.layout,
      // Scroll, focus, and tree selection intentionally have independent paths: navigating the
      // sidebar must not retarget a restored source selection in another rendered file.
      diffSelectedPath: durableDiffPosition?.path ?? null,
      diffTreeExpandedPaths,
      diffTreeSelectedPath,
      editorSidebarMode: editorUIState.sidebarMode,
      editorRecentPaths: editorUIState.recentPaths,
      selectedAgentSessionId:
        lastCommentsToolbarState.agents.find((agent) => agent.id === lastCommentsToolbarState.selectedAgentId)?.sessionId ?? null,
      pendingAgentLaunch: pendingAgentLaunch ?? null,
      fileTreeExpandedPaths,
      fileTreeSelectedPath: state.editorPath ?? null,
      diffScrollLine: durableDiffPosition?.line ?? null,
      diffScrollSide: durableDiffPosition?.side ?? null,
      diffFocusedPath: focusedDiffPosition?.path ?? null,
      diffFocusedLine: focusedDiffPosition?.line ?? null,
      diffFocusedSide: focusedDiffPosition?.side ?? null,
      editorScrollLine: durableEditorScrollLine,
      editorFocusedLine: durableEditorFocusedLine,
      editorState: editorView.snapshot() ?? null,
      diffEditorState: diffEditorState ?? null,
      pendingReviewComments: pending === null ? null : JSON.parse(pending),
    };
  }

  function pushWorkspaceState(): void {
    if (workspaceStatePushTimer !== undefined) {
      clearTimeout(workspaceStatePushTimer);
      workspaceStatePushTimer = undefined;
    }
    bridge.notifyWorkspaceStateChanged(workspaceStateSnapshot());
  }

  function scheduleWorkspaceStatePush(): void {
    if (workspaceStatePushTimer !== undefined) clearTimeout(workspaceStatePushTimer);
    workspaceStatePushTimer = setTimeout(() => {
      workspaceStatePushTimer = undefined;
      bridge.notifyWorkspaceStateChanged(workspaceStateSnapshot());
    }, WORKSPACE_STATE_DEBOUNCE_MS);
  }

  window.__spacesCollectWorkspaceState = () => {
    if (workspaceStatePushTimer !== undefined) {
      clearTimeout(workspaceStatePushTimer);
      workspaceStatePushTimer = undefined;
    }
    return JSON.stringify(workspaceStateSnapshot(true));
  };

  function renderChangesList(): void {
    renderFileList(
      changesListEl,
      files,
      diffTreeSelectedPath ?? undefined,
      {
        onSelect: changesOnSelect,
        onExpandedPathsChange: (expandedPaths) => {
          diffTreeExpandedPaths = [...expandedPaths];
          pushWorkspaceState();
        },
      },
      diffTreeExpandedPaths,
    );
  }

  /** Patch streaming changes a row's loading/stat adornment but not the manifest's tree shape.
   * Preserve the existing tree, selection, expansion state, and row listeners unless a newer
   * manifest has already replaced it. */
  function updateChangesListRow(file: DiffFileEntry): void {
    // A queued/streaming row inside a collapsed directory has no DOM node yet, but it is still
    // part of the current manifest. Its backing `files` entry was updated by the caller, so leave
    // the tree intact and let the row materialize with the latest state when the directory opens.
    // Only a missing path means a newer manifest replaced this tree and the authoritative list
    // needs to be rendered again.
    if (updateFileListRow(changesListEl, file) === "stale") renderChangesList();
  }

  function selectConfiguredBaseBranch(baseBranch: string): void {
    const token = ++configuredBaseSelectionToken;
    void bridge
      .workspaceRefList()
      .then((refs) => {
        if (token !== configuredBaseSelectionToken) return;
        const remoteOnlyName = `origin/${baseBranch}`;
        const refName = refs.branches.includes(baseBranch)
          ? baseBranch
          : refs.branches.includes(remoteOnlyName)
            ? remoteOnlyName
            : baseBranch;
        dispatch({ type: "setScope", scope: { kind: "ref", refName } }, refName);
      })
      .catch(() => {
        // Leave the current scope unchanged when the lazy listing cannot be read; activating the
        // preset again retries the same single lookup, just like the ref-search overlay does.
      });
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
      diffSelectedPath = path;
      diffTreeSelectedPath = path;
      const selected = files.find((file) => file.path === path);
      if (selected?.patchState === "queued") prioritizedPatchPath = path;
      renderChangesList();
      diffView.scrollToFile(path);
      pushWorkspaceState();
    } else {
      // A submodule (gitlink) row points at another repository's commit, not a file in this
      // workspace — there is nothing for the standalone Editor to open. `openInEditor` would
      // otherwise start a `workspaceFileRead` for the submodule's directory path and surface a
      // read-error banner; staying a no-op here just leaves the Changes list selection as-is.
      // The manifest flag is checked too so a click before the metadata-only chunk lands behaves
      // the same as one after it.
      const selected = files.find((file) => file.path === path);
      if (selected?.isSubmodule === true || selected?.submodule !== undefined) return;
      openInEditor(path);
    }
  }

  // A running agent set changes independently of any diff refresh or user action in this pane
  // (an agent can start or exit from elsewhere in the app), so this listens for the whole
  // lifetime of the pane rather than being read once at startup like `initPayload.agents`.
  window.addEventListener(AGENTS_EVENT, (event) => {
    const agents = (event as CustomEvent<CodePaneAgentsChangedEvent>).detail.agents;
    comments.onAgentsChanged(agents, pendingStartingAgentSessionId());
  });

  window.addEventListener(AGENT_START_STATUS_EVENT, (event) => {
    const detail = (event as CustomEvent<CodePaneAgentStartStatusEvent>).detail;
    const launch = pendingAgentLaunch;
    if (!launch || launch.sessionId === null || detail.sessionId !== launch.sessionId) return;
    const command = launch.command;
    clearAgentResumeTracking();
    agentStarting = false;
    if (detail.status === "detected" && detail.agent !== undefined) {
      pendingAgentLaunch = undefined;
      comments.onAgentDetected(detail.agent);
      return;
    }
    pendingAgentLaunch = {
      sessionId: launch.sessionId,
      command,
      status: "failed",
      message: detail.message ?? null,
      deadlineEpochMilliseconds: null,
    };
    startAgentInput.value = command;
    setStartAgentStatus(failedAgentStatusText(pendingAgentLaunch));
    startAgentDialog.hidden = false;
    toolbar.update(buildToolbarState());
    pushWorkspaceState();
    // Keep the code surface focused after a launch fails detection. The dialog remains visible
    // with the command retained for correction, but reopening it must not steal focus from the
    // editor the user was working in.
    focusCodeSurface();
  });

  window.addEventListener(SET_MODE_EVENT, (event) => {
    const { mode } = (event as CustomEvent<CodePaneSetModeEvent>).detail;
    // The host doesn't know this pane's live JS state before pushing (see `currentMode`'s doc
    // comment in the Swift host); redundantly dispatching the mode it's already in would still
    // schedule a redundant state write and possibly `refreshDiff` for nothing (see `dispatch`'s
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
      baseBranchRefName: configuredBaseRefName,
      agents: lastCommentsToolbarState.agents,
      selectedAgentId: lastCommentsToolbarState.selectedAgentId,
      agentStarting,
      draftCount: lastCommentsToolbarState.draftCount,
    };
  }

  const toolbar = renderToolbar(toolbarHost, buildToolbarState(), {
    onModeChange: (mode) => dispatch({ type: "setMode", mode }),
    onScopeChange: (scope) => dispatch({ type: "setScope", scope }),
    onBaseBranchSelect: selectConfiguredBaseBranch,
    onOpenRefSearch: (mode) => refSearchDialog.show(mode),
    onLayoutChange: (layout) => dispatch({ type: "setLayout", layout }),
    onAgentSelect: (id) => comments.onAgentSelected(id),
    onStartAgent: () => showStartAgentDialog(),
    onSendBatch: () => void comments.sendBatch(),
  });

  const startAgentDialog = document.createElement("div");
  startAgentDialog.className = "agent-command-dialog";
  startAgentDialog.id = "code-pane-start-agent-dialog";
  startAgentDialog.hidden = true;
  startAgentDialog.setAttribute("role", "dialog");
  const startAgentTitle = document.createElement("h2");
  startAgentTitle.id = "code-pane-start-agent-title";
  startAgentTitle.textContent = "Start an agent to receive review comments";
  startAgentDialog.setAttribute("aria-labelledby", startAgentTitle.id);
  const startAgentForm = document.createElement("form");
  const startAgentInput = document.createElement("input");
  startAgentInput.id = "code-pane-start-agent-command";
  startAgentInput.name = "command";
  startAgentInput.autocomplete = "off";
  startAgentInput.setAttribute("autocapitalize", "none");
  startAgentInput.placeholder = "Command to run in this workspace";
  const startAgentStatus = document.createElement("div");
  startAgentStatus.className = "agent-command-status";
  startAgentStatus.id = "code-pane-start-agent-status";
  startAgentStatus.setAttribute("role", "status");
  startAgentStatus.setAttribute("aria-live", "polite");
  startAgentStatus.setAttribute("aria-atomic", "true");
  startAgentStatus.setAttribute("aria-label", "");
  const startAgentActions = document.createElement("div");
  startAgentActions.className = "agent-command-actions";
  const startAgentCancel = document.createElement("button");
  startAgentCancel.type = "button";
  startAgentCancel.className = "btn";
  startAgentCancel.id = "code-pane-start-agent-cancel";
  startAgentCancel.textContent = "Cancel";
  const startAgentSubmit = document.createElement("button");
  startAgentSubmit.type = "submit";
  startAgentSubmit.className = "btn primary";
  startAgentSubmit.id = "code-pane-start-agent-submit";
  startAgentSubmit.textContent = "Run";
  startAgentSubmit.disabled = true;
  startAgentActions.append(startAgentCancel, startAgentSubmit);
  startAgentForm.append(startAgentInput, startAgentStatus, startAgentActions);
  startAgentDialog.append(startAgentTitle, startAgentForm);
  pane.appendChild(startAgentDialog);

  function setStartAgentStatus(text: string): void {
    startAgentStatus.textContent = text;
    // WebKit exposes a live region's accessible name as AXDescription, while AXValue belongs to
    // editable controls. Keep the status message in the semantic name so native clients can read
    // the same text VoiceOver announces without traversing implementation-only descendants.
    startAgentStatus.setAttribute("aria-label", text);
  }

  function showStartAgentDialog(): void {
    const failedLaunch = pendingAgentLaunch?.status === "failed" ? pendingAgentLaunch : undefined;
    setStartAgentStatus(startAgentRequestInFlight
      ? "Starting agent…"
      : failedLaunch
        ? failedAgentStatusText(failedLaunch)
        : "");
    startAgentDialog.hidden = false;
    startAgentInput.value = failedLaunch?.command ?? startAgentRequestCommand ?? "";
    startAgentSubmit.disabled = startAgentRequestInFlight || startAgentInput.value.trim().length === 0;
    queueMicrotask(() => startAgentInput.focus());
  }

  function hideStartAgentDialog(): void {
    startAgentDialog.hidden = true;
    focusCodeSurface();
  }

  /** Returns focus to whichever code surface is visible after the command dialog closes. */
  function focusCodeSurface(): void {
    (state.mode === "diff" ? diffAreaEl : editorContainerEl).focus();
  }

  function failedAgentStatusText(launch: PendingAgentLaunch): string {
    const message = launch.message?.trim();
    return message && message !== "No agent detected" ? `No agent detected\n${message}` : "No agent detected";
  }

  function clearAgentResumeTracking(): void {
    if (agentResumeRetryTimer !== undefined) clearTimeout(agentResumeRetryTimer);
    if (agentResumeDeadlineTimer !== undefined) clearTimeout(agentResumeDeadlineTimer);
    agentResumeRetryTimer = undefined;
    agentResumeDeadlineTimer = undefined;
    agentResumeRetryFailures = 0;
    agentResumeFinalReconciliation = false;
    agentResumeGeneration += 1;
  }

  function isCurrentStartingLaunch(sessionId: string, deadlineEpochMilliseconds: number): boolean {
    const launch = pendingAgentLaunch;
    return launch?.status === "starting" && launch.sessionId === sessionId && launch.deadlineEpochMilliseconds === deadlineEpochMilliseconds;
  }

  function failRestoredAgentLaunch(sessionId: string, deadlineEpochMilliseconds: number, message: string): void {
    if (!isCurrentStartingLaunch(sessionId, deadlineEpochMilliseconds)) return;
    clearAgentResumeTracking();
    const launch = pendingAgentLaunch;
    if (launch === undefined || launch.status !== "starting") return;
    pendingAgentLaunch = {
      sessionId: launch.sessionId,
      command: launch.command,
      status: "failed",
      message,
      deadlineEpochMilliseconds: null,
    };
    agentStarting = false;
    toolbar.update(buildToolbarState());
    pushWorkspaceState();
  }

  function isTransientAgentResumeError(error: unknown): boolean {
    if (SpacesBridgeError.isSpacesBridgeError(error)) return error.code === "unavailable";
    return error instanceof Error && /time(?:d)?\s*out|timeout/i.test(error.message);
  }

  function resumeRestoredAgentLaunch(finalReconciliation = false): void {
    const launch = pendingAgentLaunch;
    if (launch?.status !== "starting") return;
    const { sessionId, deadlineEpochMilliseconds } = launch;
    if (Date.now() >= deadlineEpochMilliseconds && !finalReconciliation) {
      resumeRestoredAgentLaunch(true);
      return;
    }
    if (finalReconciliation && agentResumeFinalReconciliation) return;
    const generation = ++agentResumeGeneration;
    if (finalReconciliation) {
      agentResumeFinalReconciliation = true;
      if (agentResumeRetryTimer !== undefined) clearTimeout(agentResumeRetryTimer);
      if (agentResumeDeadlineTimer !== undefined) clearTimeout(agentResumeDeadlineTimer);
      agentResumeRetryTimer = undefined;
      agentResumeDeadlineTimer = undefined;
    } else if (agentResumeDeadlineTimer === undefined) {
      agentResumeDeadlineTimer = setTimeout(() => {
        agentResumeDeadlineTimer = undefined;
        resumeRestoredAgentLaunch(true);
      }, Math.max(deadlineEpochMilliseconds - Date.now(), 0));
    }
    void bridge
      .resumeWorkspaceCommandTracking(sessionId)
      .then((result) => {
        if (generation !== agentResumeGeneration || !isCurrentStartingLaunch(sessionId, deadlineEpochMilliseconds)) return;
        // Native mints this deadline once when the command launches. Retain the restored value
        // rather than treating a resume reply as a fresh readiness window.
        if (result.sessionId !== sessionId) {
          failRestoredAgentLaunch(sessionId, deadlineEpochMilliseconds, "Could not resume this agent launch.");
          return;
        }
        if (finalReconciliation) return;
        agentResumeRetryFailures = 0;
        pushWorkspaceState();
      })
      .catch((error: unknown) => {
        if (generation !== agentResumeGeneration || !isCurrentStartingLaunch(sessionId, deadlineEpochMilliseconds)) return;
        if (finalReconciliation) {
          failRestoredAgentLaunch(sessionId, deadlineEpochMilliseconds, "Timed out waiting for an agent to start.");
          return;
        }
        if (Date.now() >= deadlineEpochMilliseconds) {
          resumeRestoredAgentLaunch(true);
          return;
        }
        if (!isTransientAgentResumeError(error)) {
          failRestoredAgentLaunch(
            sessionId,
            deadlineEpochMilliseconds,
            error instanceof Error ? error.message : "Could not resume this agent launch.",
          );
          return;
        }
        const remaining = deadlineEpochMilliseconds - Date.now();
        const delay = Math.min(AGENT_RESUME_RETRY_FLOOR_MS * 2 ** agentResumeRetryFailures, AGENT_RESUME_RETRY_CAP_MS, remaining);
        agentResumeRetryFailures += 1;
        agentResumeRetryTimer = setTimeout(() => {
          agentResumeRetryTimer = undefined;
          resumeRestoredAgentLaunch();
        }, delay);
      });
  }

  startAgentCancel.addEventListener("click", hideStartAgentDialog);
  startAgentInput.addEventListener("input", () => {
    startAgentSubmit.disabled = startAgentRequestInFlight || startAgentInput.value.trim().length === 0;
  });
  startAgentForm.addEventListener("submit", (event) => {
    event.preventDefault();
    const command = startAgentInput.value;
    if (command.trim().length === 0 || startAgentRequestInFlight) return;
    startAgentRequestInFlight = true;
    startAgentRequestCommand = command;
    setStartAgentStatus("Starting agent…");
    startAgentSubmit.disabled = true;
    void bridge
      .startWorkspaceCommand(command)
      .then((result) => {
        startAgentRequestInFlight = false;
        startAgentRequestCommand = undefined;
        clearAgentResumeTracking();
        pendingAgentLaunch = {
          sessionId: result.sessionId,
          command,
          status: "starting",
          message: null,
          deadlineEpochMilliseconds: result.deadlineEpochMilliseconds,
        };
        agentStarting = true;
        toolbar.update(buildToolbarState());
        pushWorkspaceState();
        hideStartAgentDialog();
      })
      .catch((error: unknown) => {
        startAgentRequestInFlight = false;
        startAgentRequestCommand = undefined;
        agentStarting = false;
        pendingAgentLaunch = {
          sessionId: null,
          command,
          status: "failed",
          message: error instanceof Error ? error.message : null,
          deadlineEpochMilliseconds: null,
        };
        setStartAgentStatus(failedAgentStatusText(pendingAgentLaunch));
        pushWorkspaceState();
      })
      .finally(() => {
        startAgentSubmit.disabled = startAgentRequestInFlight || startAgentInput.value.trim().length === 0;
        toolbar.update(buildToolbarState());
      });
  });

  if (pendingAgentLaunch?.status === "starting") {
    resumeRestoredAgentLaunch();
  }

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
  comments.restorePendingState(initPayload.workspaceState.pendingReviewComments ?? []);

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
    const showingDiff = state.mode === "diff";
    // The native host uses this one stable identifier to restore focus after the command dialog
    // closes. Only the mounted code surface may own it; keeping it off the detached surface avoids
    // duplicate DOM IDs and makes AX lookup unambiguous across mode switches.
    if (showingDiff) {
      diffAreaEl.id = "code-pane-editor-focus";
      editorContainerEl.removeAttribute("id");
    } else {
      diffAreaEl.removeAttribute("id");
      editorContainerEl.id = "code-pane-editor-focus";
    }
    body.replaceChildren();
    fileListEl.replaceChildren(showingDiff ? changesListEl : editorSidebar.el);
    body.appendChild(fileListEl);
    body.appendChild(fileListDividerEl);
    body.appendChild(showingDiff ? diffAreaEl : editorContainerEl);
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

  /** Removes a mutable editor before a Last Commit manifest (or its signature refresh) can render.
   * Its one safe restoration path is the immutable revision guard after that manifest's file patch
   * completes. `rebuildComparison` distinguishes entering this scope from refreshing within it. */
  function hibernateLastCommitDiffEditor(rebuildComparison: boolean): void {
    if (diffEditorState === undefined || (!rebuildComparison && state.scope.kind !== "lastCommit")) return;
    if (rebuildComparison) pendingLastCommitComparisonRebuild = true;
    if (pendingLastCommitDiffEditorRestore) return;
    pendingLastCommitDiffEditorRestore = true;
    if (pendingScopeTransitionDiffEditorRestore) return;
    diffEditRequestToken += 1;
    diffEditSessionToken += 1;
    diffView.endEdit(diffEditorState.path);
  }

  function hibernateDiffEditorForScopeTransition(): void {
    if (diffEditorState === undefined || pendingScopeTransitionDiffEditorRestore) return;
    pendingScopeTransitionDiffEditorRestore = true;
    diffEditRequestToken += 1;
    diffEditSessionToken += 1;
    diffView.endEdit(diffEditorState.path);
  }

  /** A failed Last Commit manifest has not supplied a new immutable revision to validate, so the
   * already-verified editor remains the only safe surface to restore. A successful manifest always
   * takes the separate revision guard path below; entering Last Commit from another comparison has
   * no prior Last Commit baseline and stays dormant until that path completes. */
  function restoreLastCommitDiffEditorAfterFailedRefresh(): void {
    const saved = diffEditorState;
    if (
      !pendingLastCommitDiffEditorRestore ||
      pendingLastCommitComparisonRebuild ||
      !lastCommitDiffEditorVerified ||
      !saved ||
      state.scope.kind !== "lastCommit"
    ) return;
    if (!diffView.beginEdit(saved.path, saved.content, saved.dirty, saved.comparisonOldContent)) return;
    if (saved.conflict) {
      diffView.setEditConflict(
        saved.path,
        saved.conflictBaseSHA256 === null ? { kind: "deleted" } : { kind: "changed", diskContent: saved.baseContent },
      );
    }
    pendingLastCommitDiffEditorRestore = false;
    diffEditSessionToken += 1;
  }

  /** A Last Commit edit is saveable only after this page has verified its immutable target. If a
   * transition into that scope cannot finish, keep the draft durable and direct the user to the
   * ordinary comparison where its existing CAS baseline is still safe to use. */
  function showLastCommitDraftRecoveryGuidance(message: string): void {
    diffView.showEditError(`${message} Switch to Uncommitted to continue editing this draft.`);
  }

  /** A failed diff load must never strand a hibernated dirty draft. A verified Last Commit editor
   * can reattach to its existing immutable baseline; entering Last Commit cannot, so it remains a
   * visible, review-only recovery state until the user returns to Uncommitted or a retry verifies
   * the newly streamed target. */
  function recoverDirtyDiffEditorAfterFailedRefresh(message: string, error?: unknown): void {
    const saved = diffEditorState;
    if (!saved?.dirty) return;
    if (state.scope.kind === "lastCommit") {
      if (!pendingLastCommitComparisonRebuild && lastCommitDiffEditorVerified) {
        restoreLastCommitDiffEditorAfterFailedRefresh();
        diffView.showEditError(message);
      } else if (pendingLastCommitDiffEditorRestore) {
        showLastCommitDraftRecoveryGuidance("Couldn't load Last Commit.");
      }
      return;
    }
    const wasHibernatedForScopeTransition = pendingScopeTransitionDiffEditorRestore;
    restoreScopeTransitionDiffEditorAfterFailedRefresh(saved.path, error);
    // The scope recovery already explains that Save/Cancel remains available. Retain that more
    // actionable wording; an ordinary same-scope refresh still needs the generic transport error.
    if (!wasHibernatedForScopeTransition) diffView.showEditError(message);
  }

  /** A failed comparison refresh has not supplied a replacement left side. Keep the already
   * rendered editor usable rather than marooning its dirty buffer behind a failed scope request.
   * A missing live file is an explicit recreate-or-discard conflict; every other failure preserves
   * the saved CAS target and is retried only by a later deliberate refresh/scope change. */
  function restoreScopeTransitionDiffEditorAfterFailedRefresh(path: string, error?: unknown): void {
    const saved = diffEditorState;
    if (
      !pendingScopeTransitionDiffEditorRestore || !saved || saved.path !== path ||
      state.scope.kind === "lastCommit"
    ) return;
    const restored = error instanceof SpacesBridgeError && error.code === "notFound"
      ? { ...saved, conflict: true, conflictBaseSHA256: null }
      : saved;
    if (!diffView.beginEdit(restored.path, restored.content, restored.dirty, restored.comparisonOldContent)) return;
    if (restored.conflict) {
      diffView.setEditConflict(
        restored.path,
        restored.conflictBaseSHA256 === null ? { kind: "deleted" } : { kind: "changed", diskContent: restored.baseContent },
      );
    }
    diffEditorState = restored;
    pendingScopeTransitionDiffEditorRestore = false;
    diffEditSessionToken += 1;
    diffView.showEditError(`Couldn't update ${path}'s comparison. Save or Cancel this edit, then try again.`);
    pushWorkspaceState();
  }

  /** Restores a hibernated editor only after the new scope has supplied the completed patch that
   * defines its comparison side. The worktree CAS baseline remains the one the user was editing;
   * changing a review scope must not rewrite a dirty buffer or silently adopt a different disk
   * target. Last Commit has its stricter immutable-revision guard below. */
  async function restoreScopeTransitionDiffEditor(path: string, restoreToken: number): Promise<void> {
    const saved = diffEditorState;
    if (
      !pendingScopeTransitionDiffEditorRestore ||
      !saved ||
      saved.path !== path ||
      state.scope.kind === "lastCommit" ||
      restoreToken !== diffRequestToken
    ) return;
    try {
      const result = await readDiffEditBaseline(path, performance.now());
      if (
        result.kind !== "ready" ||
        !pendingScopeTransitionDiffEditorRestore ||
        diffEditorState !== saved ||
        saved.path !== path ||
        restoreToken !== diffRequestToken
      ) return;
      const completedFile = files.find((file) => file.path === path && file.patchState === "ready");
      // No manifest entry means `readDiffEditBaseline` made an ordinary live read, whose wire
      // payload explicitly encodes its unrequested comparison as null. This recovery editor has
      // no comparison patch, so its new scope's disk baseline is the only valid synthetic left side.
      const comparisonOldContent = completedFile === undefined
        ? result.disk.content
        : result.comparisonOldContent !== undefined
          ? result.comparisonOldContent
          : diffView.prepareEdit(path, result.disk.content)?.oldContent;
      if (comparisonOldContent === undefined) {
        diffView.showEditError(`Couldn't open ${path} for editing. Try again.`);
        return;
      }
      const restoredContent = saved.dirty ? saved.content : result.disk.content;
      const prepared = diffView.prepareEdit(path, restoredContent, comparisonOldContent);
      if (prepared === undefined || !diffView.beginPreparedEdit(prepared, saved.dirty)) {
        diffView.showEditError(`Couldn't open ${path} for editing. Try again.`);
        return;
      }
      if (saved.conflict) {
        diffView.setEditConflict(
          path,
          saved.conflictBaseSHA256 === null ? { kind: "deleted" } : { kind: "changed", diskContent: saved.baseContent },
        );
      }
      diffEditorState = saved.dirty
        ? { ...saved, comparisonOldContent: prepared.oldContent }
        : {
            ...saved,
            baseSHA256: result.disk.sha256,
            baseContent: result.disk.content,
            content: result.disk.content,
            comparisonOldContent: prepared.oldContent,
          };
      pendingScopeTransitionDiffEditorRestore = false;
      diffEditSessionToken += 1;
      pushWorkspaceState();
    } catch (error) {
      if (restoreToken !== diffRequestToken || diffEditorState !== saved) return;
      restoreScopeTransitionDiffEditorAfterFailedRefresh(path, error);
    }
  }

  /** Reads every bounded metadata page before handing the sidebar a manifest. A manifest lease pins
   * the enumeration, so every page must repeat its id and signature; accepting a mixed sequence
   * would make a later patch request address a different plan than the rendered sidebar. */
  async function readCompleteManifest(
    scope: import("../bridge/types").DiffScope,
    token: number,
  ): Promise<WorkspaceDiffManifestChunkResult> {
    let manifestID: string | undefined;
    let scopeSignature: string | undefined;
    const files: WorkspaceDiffManifestChunkResult["files"] = [];
    let fileIndex = 0;
    try {
      while (true) {
        if (token !== diffRequestToken) throw new Error("Diff metadata load was superseded.");
        const page = await bridge.workspaceDiffManifestChunk(scope, { manifestID, fileIndex });
        if (manifestID === undefined) {
          manifestID = page.manifestID;
          scopeSignature = page.scopeSignature;
        } else if (page.manifestID !== manifestID || page.scopeSignature !== scopeSignature) {
          throw new Error("The diff manifest changed while its metadata was loading.");
        }
        // The first page mints a manifest lease before it reaches this page. Capture it before
        // checking supersession so the catch path can release a late response that never renders.
        if (token !== diffRequestToken) throw new Error("Diff metadata load was superseded.");
        for (const file of page.files) files.push(file);
        if (page.nextFileIndex === undefined) {
          return { manifestID, scopeSignature: scopeSignature!, files };
        }
        if (page.nextFileIndex <= fileIndex) throw new Error("The diff manifest metadata cursor did not advance.");
        fileIndex = page.nextFileIndex;
      }
    } catch (error) {
      if (manifestID !== undefined) void bridge.workspaceDiffManifestRelease(scope, { manifestID }).catch(() => {});
      throw error;
    }
  }

  async function doRefreshDiff(preserveScroll: boolean, trigger: DiffRenderTrigger): Promise<void> {
    const renderStartedAt = performance.now();
    const token = ++diffRequestToken;
    const scope = state.scope;
    hibernateLastCommitDiffEditor(false);
    clearTimeout(diffRetryTimer);
    let manifest: WorkspaceDiffManifestChunkResult;
    let fetchElapsedMs: number;
    try {
      manifest = await readCompleteManifest(scope, token);
      fetchElapsedMs = Math.round(Math.max(performance.now() - renderStartedAt, 0));
    } catch (err) {
      if (token !== diffRequestToken) return; // superseded: a newer refresh already won, so this failure is moot
      recoverDirtyDiffEditorAfterFailedRefresh("Couldn't load diff. Try again.", err);
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
          renderChangesList();
          diffView.setError(err.message);
          // The comments controller re-anchors drafts against whatever file list it was last
          // given; since the rendered diff is being cleared for this typed error, its anchor
          // input must clear too, or a batch sent while the error is showing would carry line
          // numbers from a diff the UI no longer displays. (The untyped/transport branch below
          // deliberately does NOT do this — it keeps the old diff rendered while retrying, so the
          // old anchors remain correct.)
          comments.setFiles([]);
          scheduleDiffRetry(preserveScroll, token, trigger);
          return;
        }
        // Reset here (not just on a normal success) so a later transient failure — once this
        // scope's state changes and a fresh refreshDiff runs — starts its own backoff at the
        // floor instead of inheriting whatever count this permanently-failing run left behind.
        diffRetryFailures = 0;
        files = [];
        renderChangesList();
        diffView.setError(err.message);
        // Same re-anchor reasoning as the retryable branch above: this is a durable rejection
        // (e.g. a bad ref), so the diff stays cleared indefinitely and comments' anchor state
        // must match what's on screen (nothing).
        comments.setFiles([]);
        return;
      }
      recoverDirtyDiffEditorAfterFailedRefresh("Couldn't load diff. Try again.");
      scheduleDiffRetry(preserveScroll, token, trigger);
      return;
    }
    if (token !== diffRequestToken) {
      // A manifest allocates a server-side snapshot before it reaches the page. A newer generation
      // can win during this await, before `activeManifest` exists to be released by refreshDiff.
      void bridge.workspaceDiffManifestRelease(scope, { manifestID: manifest.manifestID }).catch(() => {});
      return;
    }
    diffRetryFailures = 0;
    activeManifest = { scope, manifestID: manifest.manifestID, token };
    files = manifest.files.map((file) => ({ ...file, isBinary: false, patchState: "queued" as const }));
    diffLoaded = true;
    renderChangesList();
    diffView.setFiles(files, preserveScroll);
    if (!initialDiffScrollRestored) {
      diffView.restorePosition(
        initPayload.workspaceState.diffSelectedPath,
        initPayload.workspaceState.diffScrollLine,
        initPayload.workspaceState.diffScrollSide,
        initPayload.workspaceState.diffFocusedPath,
        initPayload.workspaceState.diffFocusedLine,
        initPayload.workspaceState.diffFocusedSide,
      );
    }
    initialDiffScrollRestored = true;
    if (diffEditorState !== undefined && !pendingLastCommitDiffEditorRestore && !pendingScopeTransitionDiffEditorRestore) {
      diffView.beginEdit(diffEditorState.path, diffEditorState.content, diffEditorState.dirty, diffEditorState.comparisonOldContent);
      if (diffEditorState.conflict) {
        // The durable conflict target is the same disk side the user last compared. `null` means
        // that side was absent, so the restored action must recreate the file instead of CASing
        // against the stale pre-deletion hash.
        diffView.setEditConflict(
          diffEditorState.path,
          diffEditorState.conflictBaseSHA256 === null
            ? { kind: "deleted" }
            : { kind: "changed", diskContent: diffEditorState.baseContent },
        );
      } else if (!diffEditorState.dirty) {
        // A clean editor restored from hibernation can outlive its diff membership: an agent may
        // commit/reset the file while this pane is away, so wait for the workspace read rather
        // than trusting the persisted buffer or requiring the manifest to contain this path.
        void reconcileDiffEditWithDisk(diffEditorState.path);
      }
    }
    comments.setFiles(files);
    // The manifest gives comments stable queued anchors immediately. Do not hold the workspace
    // draft list behind every patch in a large progressive stream.
    void loadInitialComments();
    await browserPaint();
    if (token !== diffRequestToken) {
      releaseManifestIfOwned(scope, manifest.manifestID, token);
      return;
    }
    // Hold patch scheduling through the actual sidebar/placeholder paint: otherwise a fast local
    // first patch can win the event loop and users still observe an empty pane.
    if (state.mode === "diff") {
      bridge.notifyRenderMetric({
        kind: "diff",
        trigger: "manifest",
        elapsedMs: Math.round(Math.max(performance.now() - renderStartedAt, 0)),
        fetchElapsedMs,
        fileCount: files.length,
        contentBytes: 0,
        scope: renderMetricScope(scope),
      });
    }
    try {
      await streamManifestPatches(manifest, scope, token, renderStartedAt, trigger);
    } catch {
      if (token !== diffRequestToken) return;
      // A manifest still describes a valid ordered file set when one transfer is interrupted. Keep
      // files whose patches already painted visible, move only the interrupted row back to queued,
      // and retry from a fresh manifest after bounded backoff. `notFound` is deliberately treated
      // this way too: a lost EOF/replayed chunk is recoverable by a fresh generation, not a durable
      // user-facing rejection of the comparison scope.
      const interruptedIndex = files.findIndex((file) => file.patchState === "streaming");
      if (interruptedIndex >= 0) {
        const queued = { ...files[interruptedIndex]!, patchState: "queued" as const };
        files[interruptedIndex] = queued;
        diffView.updateFile(queued);
        renderChangesList();
      }
      recoverDirtyDiffEditorAfterFailedRefresh("Couldn't load diff. Try again.");
      scheduleDiffRetry(preserveScroll, token, trigger);
    }
  }

  function releaseManifestIfOwned(scope: import("../bridge/types").DiffScope, manifestID: string, token: number): void {
    const active = activeManifest;
    if (active?.token !== token || active.manifestID !== manifestID) return;
    activeManifest = undefined;
    void bridge.workspaceDiffManifestRelease(scope, { manifestID }).catch(() => {});
  }

  /** Streams one leased manifest enumeration serially. Keeping only one transfer alive avoids
   * queueing 4 MiB chunks behind each other during agent churn; a sidebar click merely moves a
   * not-yet-started file to the next slot, never starves the patch already on screen. */
  async function streamManifestPatches(
    manifest: WorkspaceDiffManifestChunkResult,
    scope: import("../bridge/types").DiffScope,
    token: number,
    renderStartedAt: number,
    trigger: DiffRenderTrigger,
  ): Promise<void> {
    const pending = manifest.files.map((file, index) => ({ path: file.path, index }));
    let streamedOutOfManifestOrder = false;
    try {
      while (pending.length > 0) {
        if (token !== diffRequestToken) return;
        let nextIndex = 0;
        let selectedPriority = false;
        if (prioritizedPatchPath !== undefined) {
          const found = pending.findIndex((entry) => entry.path === prioritizedPatchPath);
          if (found >= 0) {
            nextIndex = found;
            selectedPriority = found !== 0;
            streamedOutOfManifestOrder ||= selectedPriority;
          }
          prioritizedPatchPath = undefined;
        }
        const next = pending.splice(nextIndex, 1)[0]!;
        const queued = files[next.index];
        if (!queued) return;
        const streaming = { ...queued, patchState: "streaming" as const };
        files[next.index] = streaming;
        diffView.updateFile(streaming);
        updateChangesListRow(streaming);

        const decoder = new TextDecoder();
        // Concatenating each decoded chunk repeatedly copies the entire accumulated string. Large
        // agent churn diffs commonly cross the transport boundary, so retain chunk strings and
        // allocate the complete patch exactly once at terminal decode.
        const patchChunks: string[] = [];
        let byteOffset = 0;
        let transferID: string | undefined;
        let chunkCount = 0;
        let finalFile: DiffFileEntry | undefined;
        let bridgeElapsedMs = 0;
        let decodeElapsedMs = 0;
        while (true) {
          const bridgeWaitStartedAt = performance.now();
          const chunk = await bridge.workspaceDiffFileChunk(scope, {
            manifestID: manifest.manifestID,
            relativePath: next.path,
            byteOffset,
            transferID,
          });
          bridgeElapsedMs += Math.max(performance.now() - bridgeWaitStartedAt, 0);
          if (token !== diffRequestToken || chunk.scopeSignature !== manifest.scopeSignature) {
            if (chunk.transferID !== undefined) {
              activePatchTransfer = undefined;
              void bridge.workspaceDiffFileChunkCancel(scope, {
                manifestID: manifest.manifestID,
                relativePath: next.path,
                byteOffset: chunk.nextByteOffset ?? byteOffset,
                transferID: chunk.transferID,
              }).catch(() => {});
            }
            return;
          }
          finalFile = chunk.file;
          if (chunk.patchBase64Data !== undefined) {
            const decodeStartedAt = performance.now();
            const decoded = decoder.decode(base64ToBytes(chunk.patchBase64Data), { stream: true });
            if (decoded) patchChunks.push(decoded);
            decodeElapsedMs += Math.max(performance.now() - decodeStartedAt, 0);
            chunkCount += 1;
          }
          if (chunk.nextByteOffset === undefined) break;
          if (chunk.transferID === undefined) throw new Error("Incomplete patch transfer did not return an id.");
          transferID = chunk.transferID;
          byteOffset = chunk.nextByteOffset;
          activePatchTransfer = { scope, manifestID: manifest.manifestID, path: next.path, byteOffset, transferID };
        }
        activePatchTransfer = undefined;
        if (token !== diffRequestToken || finalFile === undefined) return;
        const trailingDecodeStartedAt = performance.now();
        const trailingDecoded = decoder.decode();
        if (trailingDecoded) patchChunks.push(trailingDecoded);
        decodeElapsedMs += Math.max(performance.now() - trailingDecodeStartedAt, 0);
        const joinStartedAt = performance.now();
        // A submodule (gitlink) entry, like a binary file, has no patch bytes: the daemon sends
        // its `submodule` pointer metadata on the first (and only) chunk reply and no
        // `patchBase64Data`, so `patchChunks` stays empty here — treat it the same as `isBinary`
        // rather than joining an empty chunk list into a spurious `""` patch.
        const patch = finalFile.isBinary || finalFile.submodule !== undefined ? undefined : patchChunks.join("");
        decodeElapsedMs += Math.max(performance.now() - joinStartedAt, 0);
        const completed: DiffFileEntry = {
          ...files[next.index],
          ...finalFile,
          patch,
          patchState: "ready",
        };
        files[next.index] = completed;
        const updateStartedAt = performance.now();
        diffView.updateFile(completed);
        const updateElapsedMs = Math.round(Math.max(performance.now() - updateStartedAt, 0));
        const insertionCompletedAt = performance.now();
        // Queued rows do not have a CodeView item yet, so the click's initial scroll is a no-op.
        // Reveal the selected path immediately after its completed item is appended.
        if (diffSelectedPath === completed.path) diffView.revealStreamedFile(completed.path);
        updateChangesListRow(completed);
        comments.updateFile(completed);
        if (pendingLastCommitDiffEditorRestore && diffEditorState?.path === completed.path) {
          void restoreLastCommitDiffEditor(completed.path, token, completed.targetRevision);
        } else if (pendingScopeTransitionDiffEditorRestore && diffEditorState?.path === completed.path) {
          void restoreScopeTransitionDiffEditor(completed.path, token);
        }
        // Restored clean editors reconcile immediately after `beginEdit`, even when the manifest
        // omits the path. Keep this streaming hook for already-dirty/conflicted editors whose
        // external-change handling still needs the completed patch generation.
        if (!pendingLastCommitDiffEditorRestore && !pendingScopeTransitionDiffEditorRestore && diffEditorState?.path === completed.path && (diffEditorState.dirty || diffEditorState.conflict)) {
          void reconcileDiffEditWithDisk(completed.path);
        }
        afterBrowserPaint(() => {
          if (token !== diffRequestToken || state.mode !== "diff") return;
          bridge.notifyRenderMetric({
            kind: "diff",
            trigger: "filePatch",
            elapsedMs: Math.round(Math.max(performance.now() - renderStartedAt, 0)),
            fileCount: files.length,
            contentBytes: completed.patch?.length ?? 0,
            scope: renderMetricScope(scope),
            path: completed.path,
            fileIndex: next.index,
            selectedPriority: selectedPriority || undefined,
            chunkCount,
            bridgeElapsedMs: Math.round(bridgeElapsedMs),
            decodeElapsedMs: Math.round(decodeElapsedMs),
            updateElapsedMs,
            paintElapsedMs: Math.round(Math.max(performance.now() - insertionCompletedAt, 0)),
          });
        });
      }
      if (streamedOutOfManifestOrder) {
        diffView.finalizeStreamOrder();
        // `setItems` repairs the virtualizer's manifest order. Re-issue the selected-file reveal
        // because a priority-completed item may have moved from its append position.
        if (diffSelectedPath !== null && diffSelectedPath !== undefined) diffView.revealStreamedFile(diffSelectedPath);
      }
      // A scope may legitimately omit the edited path (for example, a clean worktree after a
      // Last Commit draft). Its recovery editor has no patch left side, so compare the preserved
      // dirty buffer against the newly-read disk baseline rather than leaving Save/Cancel dormant.
      if (pendingScopeTransitionDiffEditorRestore && diffEditorState !== undefined && !files.some((file) => file.path === diffEditorState!.path)) {
        void restoreScopeTransitionDiffEditor(diffEditorState.path, token);
      }
      // A dirty draft entering Last Commit has no safe left side when this immutable manifest
      // omits its path. Keep the completed review visible and leave the durable draft available
      // through Uncommitted; rendering it here would make an unverified historical edit saveable.
      if (pendingLastCommitDiffEditorRestore && diffEditorState?.dirty && !files.some((file) => file.path === diffEditorState!.path)) {
        showLastCommitDraftRecoveryGuidance("This draft is not part of Last Commit.");
      }
      afterBrowserPaint(() => {
        if (token !== diffRequestToken) return;
        // Let the final FileDiff post-render first apply a pending restored line. Clearing the
        // protected location synchronously here lets that render's ordinary reveal win instead.
        diffView.finishRestoredStream();
        if (state.mode !== "diff") return;
        bridge.notifyRenderMetric({
          kind: "diff",
          trigger: "complete",
          elapsedMs: Math.round(Math.max(performance.now() - renderStartedAt, 0)),
          fileCount: files.length,
          contentBytes: aggregateContentUnits(files.map((file) => file.patch)),
          scope: renderMetricScope(scope),
        });
      });
    } finally {
      const transfer = activePatchTransfer;
      if (transfer?.manifestID === manifest.manifestID) {
        activePatchTransfer = undefined;
        void bridge.workspaceDiffFileChunkCancel(transfer.scope, {
          manifestID: transfer.manifestID,
          relativePath: transfer.path,
          byteOffset: transfer.byteOffset,
          transferID: transfer.transferID,
        }).catch(() => {});
      }
      releaseManifestIfOwned(scope, manifest.manifestID, token);
    }
  }

  function base64ToBytes(value: string): Uint8Array {
    const binary = atob(value);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    return bytes;
  }

  type DiffEditRead =
    | { kind: "ready"; disk: WorkspaceFileReadResult; comparisonOldContent?: string | null; fetchElapsedMs: number }
    | { kind: "worktreeDiverged" }
    | { kind: "revisionUnavailable" };

  /** The Last Commit patch is fixed at a manifest-pinned revision while the worktree is mutable.
   * Git verifies checkout equivalence through its configured EOL/filter rules, preventing a CAS
   * write from applying a historical review onto an agent's newer worktree change. */
  async function readDiffEditBaseline(path: string, startedAt: number, pinnedRevision?: string): Promise<DiffEditRead> {
    if (state.scope.kind !== "lastCommit") {
      const file = files.find((candidate) => candidate.path === path);
      const comparison = file?.comparisonBaseRevision === undefined
        ? undefined
        : { baseRevision: file.comparisonBaseRevision, oldPath: file.oldPath };
      const disk = comparison === undefined
        ? await bridge.workspaceFileRead(path, "inlineDiff")
        : await bridge.workspaceFileRead(path, "inlineDiff", comparison);
      return {
        kind: "ready", disk, comparisonOldContent: disk.comparisonOldContent,
        fetchElapsedMs: Math.round(Math.max(performance.now() - startedAt, 0)),
      };
    }
    const targetFile = files.find((file) => file.path === path);
    const targetRevision = pinnedRevision ?? targetFile?.targetRevision;
    if (targetRevision === undefined) return { kind: "revisionUnavailable" };
    let revision: WorkspaceRevisionFileReadResult;
    try {
      revision = await bridge.workspaceRevisionFileRead({ path, revision: targetRevision, oldPath: targetFile?.oldPath });
    } catch (error) {
      // A Last Commit comparison names a file that existed at the immutable revision. If it has
      // disappeared from the mutable worktree, it is the same safety condition as a content hash
      // mismatch: opening its editor would turn a historical review into a write against a changed
      // workspace. Keep ordinary Uncommitted deletion handling below untouched.
      if (error instanceof SpacesBridgeError && error.code === "notFound") return { kind: "worktreeDiverged" };
      throw error;
    }
    if (revision.isWorktreeEquivalentToRevision !== true) return { kind: "worktreeDiverged" };
    const disk: WorkspaceFileReadResult = { content: revision.content, sha256: revision.sha256, size: revision.size };
    return {
      kind: "ready", disk, comparisonOldContent: revision.comparisonOldContent,
      fetchElapsedMs: Math.round(Math.max(performance.now() - startedAt, 0)),
    };
  }

  function showLastCommitEditGuardError(result: Exclude<DiffEditRead, { kind: "ready" }>): void {
    if (result.kind === "worktreeDiverged") {
      diffView.showEditError("Workspace file changed since this commit. Switch to Uncommitted to edit it.");
    } else {
      diffView.showEditError("Couldn't verify this commit's file. Switch to Uncommitted to edit it.");
    }
  }

  /** A saved Last Commit inline editor waits for its file patch so this exact same immutable
   * comparison check gates restoration. Persisted edits are never rendered against mutable churn. */
  async function restoreLastCommitDiffEditor(path: string, restoreToken: number, targetRevision: string | undefined): Promise<void> {
    const saved = diffEditorState;
    if (
      !pendingLastCommitDiffEditorRestore ||
      !saved ||
      saved.path !== path ||
      state.scope.kind !== "lastCommit" ||
      targetRevision === undefined ||
      restoreToken !== diffRequestToken
    ) return;
    const startedAt = performance.now();
    diffView.clearEditError();
    try {
      const result = await readDiffEditBaseline(path, startedAt, targetRevision);
      // A Last Commit manifest pins its target SHA. Both its refresh generation and that SHA must
      // still own this hibernated editor when the independent file reads settle; an A→B→A scope
      // round-trip or a new HEAD must never revive an editor verified against an old comparison.
      if (
        state.scope.kind !== "lastCommit" ||
        diffEditorState !== saved ||
        restoreToken !== diffRequestToken ||
        files.find((file) => file.path === path)?.targetRevision !== targetRevision
      ) return;
      if (result.kind !== "ready") {
        showLastCommitEditGuardError(result);
        return;
      }
      const comparisonOldContent = pendingLastCommitComparisonRebuild
        ? result.comparisonOldContent
        : saved.comparisonOldContent;
      if (comparisonOldContent === undefined) {
        diffView.showEditError(`Couldn't verify ${path}'s comparison side. Try again.`);
        return;
      }
      let restored: CodePaneDiffEditorState;
      if (saved.conflict) {
        // A conflict is an explicit user decision, not a stale rendering detail. A newer verified
        // Last Commit target replaces its disk/CAS side, but never silently unlocks or drops mine.
        restored = {
          ...saved,
          baseSHA256: result.disk.sha256,
          baseContent: result.disk.content,
          comparisonOldContent,
          conflict: true,
          conflictBaseSHA256: result.disk.sha256,
        };
      } else if (saved.dirty && (saved.baseSHA256 !== result.disk.sha256 || saved.baseContent !== result.disk.content)) {
        // A Last Commit refresh can advance HEAD while this pane is hibernated. Treat that exactly
        // like the live editor's external-change reconciliation: merge non-overlapping edits onto
        // the verified disk baseline, otherwise freeze the exact replacement target for an
        // explicit Keep mine/Take disk decision.
        const merged = diff3MergeLines(saved.content, saved.baseContent, result.disk.content);
        if ("merged" in merged) {
          restored = {
            path,
            baseSHA256: result.disk.sha256,
            baseContent: result.disk.content,
            comparisonOldContent,
            content: merged.merged,
            dirty: true,
            conflict: false,
            conflictBaseSHA256: null,
          };
        } else {
          restored = {
            ...saved,
            baseSHA256: result.disk.sha256,
            baseContent: result.disk.content,
            comparisonOldContent,
            conflict: true,
            conflictBaseSHA256: result.disk.sha256,
          };
        }
      } else {
        restored = {
          ...saved,
          baseSHA256: result.disk.sha256,
          baseContent: result.disk.content,
          content: saved.dirty ? saved.content : result.disk.content,
          comparisonOldContent,
          conflict: false,
          conflictBaseSHA256: null,
        };
      }
      const prepared = diffView.prepareEdit(path, restored.content, restored.comparisonOldContent);
      if (prepared === undefined || !diffView.beginPreparedEdit(prepared, restored.dirty)) {
        diffView.showEditError(`Couldn't open ${path} for editing. Try again.`);
        return;
      }
      if (restored.conflict) diffView.setEditConflict(path, { kind: "changed", diskContent: result.disk.content });
      diffEditorState = restored;
      pendingLastCommitDiffEditorRestore = false;
      pendingLastCommitComparisonRebuild = false;
      pendingScopeTransitionDiffEditorRestore = false;
      lastCommitDiffEditorVerified = true;
      diffEditSessionToken += 1;
      pushWorkspaceState();
    } catch {
      if (
        state.scope.kind !== "lastCommit" ||
        diffEditorState !== saved ||
        restoreToken !== diffRequestToken ||
        files.find((file) => file.path === path)?.targetRevision !== targetRevision
      ) return;
      showLastCommitEditGuardError({ kind: "revisionUnavailable" });
    }
  }

  /** Starts the one editable new/right-side file. The read is the CAS baseline, not the patch body:
   * a patch can be stale while an agent is actively changing the worktree, whereas every write must
   * compare against the actual workspace file the user is about to update. */
  function activateDiffEdit(
    path: string, disk: WorkspaceFileReadResult, startedAt: number, fetchElapsedMs: number, comparisonOldContent?: string | null,
  ): boolean {
    const prepared = diffView.prepareEdit(path, disk.content, comparisonOldContent);
    return prepared !== undefined && activatePreparedDiffEdit(prepared, disk, startedAt, fetchElapsedMs);
  }

  /** The dirty-editor replacement path prepares B before it discards A. Reuse that exact
   * successful hydration when B takes over so a large patch is parsed and reverse-applied once. */
  function activatePreparedDiffEdit(
    prepared: PreparedDiffEdit,
    disk: WorkspaceFileReadResult,
    startedAt: number,
    fetchElapsedMs: number,
  ): boolean {
    const path = prepared.path;
    if (!diffView.beginPreparedEdit(prepared)) return false;
    const comparisonOldContent = prepared.oldContent;
    diffEditSessionToken += 1;
    diffEditorState = {
      path,
      baseSHA256: disk.sha256,
      baseContent: disk.content,
      comparisonOldContent,
      content: disk.content,
      dirty: false,
      conflict: false,
      conflictBaseSHA256: null,
    };
    if (state.scope.kind === "lastCommit") lastCommitDiffEditorVerified = true;
    diffEditContentGeneration += 1;
    pushWorkspaceState();
    afterBrowserPaint(() => {
      if (diffEditorState?.path !== path) return;
      bridge.notifyRenderMetric({
        kind: "diff",
        trigger: "diffEdit",
        elapsedMs: Math.round(Math.max(performance.now() - startedAt, 0)),
        fetchElapsedMs,
        fileCount: files.length,
        contentBytes: disk.content.length,
        path,
      });
    });
    return true;
  }

  async function beginDiffEdit(path: string): Promise<void> {
    if (diffEditorState?.path === path) return;
    if (diffEditorState?.dirty) {
      diffView.requestOpenAfterDiscard(path);
      return;
    }
    if (diffEditorState !== undefined) {
      // A clean file still owns a live Pierre editor. End it before awaiting B's disk read so a
      // slow read cannot leave two contenteditables attached to one CodeView.
      diffView.endEdit(diffEditorState.path);
      diffEditorState = undefined;
      diffEditSessionToken += 1;
      pushWorkspaceState();
    }
    const requestToken = ++diffEditRequestToken;
    const refreshToken = diffRequestToken;
    const startedAt = performance.now();
    diffView.clearEditError();
    try {
      const result = await readDiffEditBaseline(path, startedAt);
      // File reads are asynchronous. A newer line click or a fresh diff generation owns the one
      // edit surface, even when this older read happens to resolve after it.
      if (requestToken !== diffEditRequestToken || refreshToken !== diffRequestToken) return;
      if (result.kind !== "ready") {
        showLastCommitEditGuardError(result);
      } else if (!activateDiffEdit(path, result.disk, startedAt, result.fetchElapsedMs, result.comparisonOldContent)) {
        diffView.showEditError(`Couldn't open ${path} for editing. Try again.`);
      }
    } catch (error) {
      if (requestToken !== diffEditRequestToken || refreshToken !== diffRequestToken) return;
      // A deleted target is expected under agent churn: the rendered comparison remains reviewable
      // and a subsequent refresh owns its metadata. Any other failed read leaves the user with no
      // edit surface, so make that retryable failure explicit rather than silently ignoring it.
      if (!(error instanceof SpacesBridgeError && error.code === "notFound")) {
        diffView.showEditError(error instanceof SpacesBridgeError ? error.message : `Couldn't open ${path} for editing. Try again.`);
      }
    }
  }

  /** Reads the replacement before ending a dirty edit. A failed read leaves the original buffer
   * and its Save/Cancel actions intact, while a successful read atomically hands the surface to B. */
  async function discardAndOpenDiffEdit(currentPath: string, nextPath: string): Promise<void> {
    if (diffEditorState?.path !== currentPath || !diffEditorState.dirty) return;
    const requestToken = ++diffEditRequestToken;
    const refreshToken = diffRequestToken;
    const startedAt = performance.now();
    diffView.clearEditError();
    try {
      const result = await readDiffEditBaseline(nextPath, startedAt);
      if (requestToken !== diffEditRequestToken || refreshToken !== diffRequestToken) return;
      if (diffEditorState?.path !== currentPath) return;
      if (result.kind !== "ready") {
        diffView.clearPendingOpen(currentPath);
        showLastCommitEditGuardError(result);
        return;
      }
      const prepared = diffView.prepareEdit(nextPath, result.disk.content, result.comparisonOldContent);
      if (prepared === undefined) {
        diffView.clearPendingOpen(currentPath);
        diffView.showEditError(`Couldn't open ${nextPath} for editing. Try again.`);
        return;
      }
      diffView.endEdit(currentPath);
      diffEditorState = undefined;
      diffEditSessionToken += 1;
      pushWorkspaceState();
      if (!activatePreparedDiffEdit(prepared, result.disk, startedAt, result.fetchElapsedMs)) {
        diffView.showEditError(`Couldn't open ${nextPath} for editing. Try again.`);
      }
    } catch (error) {
      if (requestToken !== diffEditRequestToken || refreshToken !== diffRequestToken) return;
      if (diffEditorState?.path !== currentPath) return;
      diffView.clearPendingOpen(currentPath);
      diffView.showEditError(
        error instanceof SpacesBridgeError && error.code !== "notFound"
          ? error.message
          : `Couldn't open ${nextPath} for editing. Try again.`,
      );
    }
  }

  function cancelDiffEdit(path: string): void {
    if (diffEditorState?.path !== path) return;
    diffEditRequestToken += 1;
    const contentBytes = diffEditorState.content.length;
    diffEditorState = undefined;
    diffEditSessionToken += 1;
    diffView.endEdit(path);
    diffView.clearEditError();
    pushWorkspaceState();
    afterBrowserPaint(() => {
      bridge.notifyRenderMetric({ kind: "diff", trigger: "diffEditCancel", elapsedMs: 0, fileCount: files.length, contentBytes, path });
    });
  }

  async function saveDiffEdit(path: string, baseSHA256: string | undefined, resolvingConflict = false): Promise<void> {
    const edit = diffEditorState;
    const editSession = diffEditSessionToken;
    if (!edit || edit.path !== path || !edit.dirty || (edit.conflict && !resolvingConflict) || diffEditSaveInFlightSession === editSession) return;
    const savedContentGeneration = diffEditContentGeneration;
    const startedAt = performance.now();
    diffEditSaveInFlightSession = editSession;
    const ownsEdit = () => diffEditSessionToken === editSession && diffEditorState?.path === path;
    try {
      const outcome = await bridge.workspaceFileWrite(path, edit.content, { baseSHA256, purpose: "inlineDiff" });
      // A cancel/discard-and-open can install another editor while this CAS write is in flight.
      // Its reply belongs only to the original session and may not clear, conflict, refresh, or
      // otherwise mutate the replacement editor.
      const currentEdit = diffEditorState;
      if (!currentEdit || !ownsEdit()) return;
      if ("ok" in outcome && outcome.ok) {
        if (diffEditContentGeneration !== savedContentGeneration) {
          // The user kept typing while the CAS write was in flight. The returned hash belongs to
          // `edit.content`, not the newer live buffer, so retain that buffer as dirty against the
          // saved contents and hash rather than closing the editor and discarding keystrokes.
          diffEditorState = {
            ...currentEdit,
            baseSHA256: outcome.sha256,
            baseContent: edit.content,
            dirty: true,
            conflict: false,
          };
          pushWorkspaceState();
          void refreshDiff(true, "workspaceChange");
          return;
        }
        diffEditorState = undefined;
        diffEditSessionToken += 1;
        diffView.endEdit(path);
        diffView.clearEditError();
        pushWorkspaceState();
        afterBrowserPaint(() => {
          bridge.notifyRenderMetric({
            kind: "diff",
            trigger: "diffEditSave",
            elapsedMs: Math.round(Math.max(performance.now() - startedAt, 0)),
            fileCount: files.length,
            contentBytes: edit.content.length,
            path,
          });
        });
        void refreshDiff(true, "workspaceChange");
      } else if ("conflict" in outcome) {
        await reconcileDiffEditWithDisk(path);
      }
    } catch (error) {
      if (!ownsEdit()) return;
      if (
        diffEditDiskConfirmedSave?.session === editSession &&
        diffEditDiskConfirmedSave.contentGeneration === diffEditContentGeneration &&
        diffEditorState?.content === edit.content &&
        diffEditorState.dirty === false &&
        diffEditorState.conflict === false
      ) {
        // The signature read already proved this exact submitted buffer is on disk. A lost or
        // rejected RPC response is therefore superseded; preserve the clean editor and avoid a
        // misleading save error. A later edit changes the generation and cannot take this path.
        diffView.clearEditError();
        return;
      }
      if (error instanceof SpacesBridgeError && error.code === "notFound") {
        diffEditorState = { ...edit, conflict: true, conflictBaseSHA256: null };
        diffView.setEditConflict(path, { kind: "deleted" });
        pushWorkspaceState();
      } else {
        // The edit state and its CAS baseline stay intact, so the same explicit Save action can
        // retry after a transient daemon/transport/permission failure.
        diffView.showEditError(error instanceof SpacesBridgeError ? error.message : `Couldn't save ${path}. Try again.`);
      }
    } finally {
      if (diffEditSaveInFlightSession === editSession) diffEditSaveInFlightSession = undefined;
    }
  }

  /** Applies the same three-way rules as EditorView: clean local edits silently adopt disk, dirty
   * non-overlaps merge, and overlaps/deletions require an explicit Keep mine/Take disk choice. */
  async function reconcileDiffEditWithDisk(path: string): Promise<void> {
    const startingEdit = diffEditorState;
    if (!startingEdit || startingEdit.path !== path) return;
    // Typing is intentionally allowed to continue while this read is in flight, but a successful
    // save can replace the CAS baseline underneath it. In that case this snapshot was requested
    // against an older baseline and must not move the newly adopted baseline backward. Comparing
    // both fields also covers the missing-file (`undefined` hash) convention.
    const startingBaseSHA256 = startingEdit.baseSHA256;
    const startingBaseContent = startingEdit.baseContent;
    const editSession = diffEditSessionToken;
    const reconcileToken = ++diffEditReconcileToken;
    try {
      const disk = await bridge.workspaceFileRead(path, "inlineDiff");
      if (reconcileToken !== diffEditReconcileToken || diffEditSessionToken !== editSession) return;
      const edit = diffEditorState;
      if (!edit || edit.path !== path) return;
      if (edit.baseSHA256 !== startingBaseSHA256 || edit.baseContent !== startingBaseContent) return;
      if (disk.sha256 === edit.baseSHA256) return;
      if (disk.content === edit.content) {
        // The workspace write can land before its CAS reply reaches this pane. Disk already holds
        // exactly the live buffer, so this refresh is the successful-save observation: adopt its
        // hash and mark the editor clean without advancing the content generation. Leaving the
        // generation unchanged lets the in-flight write reply take its normal success arm and
        // close this now-clean editor; a later keystroke still advances it and remains protected
        // by the existing newer-content branch.
        diffEditorState = {
          ...edit,
          baseSHA256: disk.sha256,
          baseContent: disk.content,
          content: disk.content,
          dirty: false,
          conflict: false,
          conflictBaseSHA256: null,
        };
        if (diffEditSaveInFlightSession === diffEditSessionToken) {
          diffEditDiskConfirmedSave = {
            session: diffEditSessionToken,
            contentGeneration: diffEditContentGeneration,
          };
        }
        diffView.replaceEditContent(path, disk.content, false);
      } else {
        // Reconciliation can replace the live document or move it into a conflict comparison while
        // a CAS save is still in flight. Advance the content generation so that an older success
        // cannot close the editor and discard the reconciled state when it settles.
        diffEditContentGeneration += 1;
        if (edit.conflict) {
          // A later external write must refresh the frozen comparison and its CAS baseline, not
          // rerun auto-merge and silently unlock editing before an explicit conflict decision.
          diffEditorState = {
            ...edit,
            baseSHA256: disk.sha256,
            baseContent: disk.content,
            conflict: true,
            conflictBaseSHA256: disk.sha256,
          };
          diffView.setEditConflict(path, { kind: "changed", diskContent: disk.content });
        } else if (!edit.dirty) {
          diffEditorState = {
            path,
            baseSHA256: disk.sha256,
            baseContent: disk.content,
            comparisonOldContent: edit.comparisonOldContent,
            content: disk.content,
            dirty: false,
            conflict: false,
            conflictBaseSHA256: null,
          };
          diffView.replaceEditContent(path, disk.content, false);
        } else {
          const merged = diff3MergeLines(edit.content, edit.baseContent, disk.content);
          if ("merged" in merged) {
            diffEditorState = {
              path,
              baseSHA256: disk.sha256,
              baseContent: disk.content,
              comparisonOldContent: edit.comparisonOldContent,
              content: merged.merged,
              dirty: true,
              conflict: false,
              conflictBaseSHA256: null,
            };
            diffView.replaceEditContent(path, merged.merged);
          } else {
            // Persist the exact disk snapshot displayed in the comparison. Keep mine uses the same
            // hash, so neither state restoration nor a later write can target a stale baseline.
            diffEditorState = {
              ...edit,
              baseSHA256: disk.sha256,
              baseContent: disk.content,
              conflict: true,
              conflictBaseSHA256: disk.sha256,
            };
            diffView.setEditConflict(path, { kind: "changed", diskContent: disk.content });
          }
        }
      }
    } catch (error) {
      if (reconcileToken !== diffEditReconcileToken || diffEditSessionToken !== editSession) return;
      const edit = diffEditorState;
      if (!edit || edit.path !== path) return;
      if (edit.baseSHA256 !== startingBaseSHA256 || edit.baseContent !== startingBaseContent) return;
      if (error instanceof SpacesBridgeError && error.code === "notFound") {
        diffEditContentGeneration += 1;
        diffEditorState = { ...edit, conflict: true, conflictBaseSHA256: null };
        diffView.setEditConflict(path, { kind: "deleted" });
      }
    }
    pushWorkspaceState();
  }

  async function resolveDiffEdit(
    path: string,
    action: "keepMine" | "takeDisk" | "closeWithoutSaving",
  ): Promise<void> {
    if (diffEditorState?.path !== path) return;
    if (action === "keepMine") {
      const edit = diffEditorState;
      const conflictBaseSHA256 = edit.conflictBaseSHA256 === null ? undefined : edit.conflictBaseSHA256;
      // The explicit conflict action is the only path that may overwrite a newer disk baseline.
      // Keep the frozen conflict state through the write: a transient failure must retry against
      // the disk snapshot the user confirmed, rather than exposing a normal Save with an older
      // baseline. A refreshed conflict replaces that snapshot with the newer disk state.
      await saveDiffEdit(path, conflictBaseSHA256, true);
      return;
    }
    cancelDiffEdit(path);
    if (action === "takeDisk") void refreshDiff(true, "workspaceChange");
  }

  /**
   * Public-facing gate every caller below keeps calling unchanged: at most one `doRefreshDiff`
   * pull is ever in flight, with at most one more coalesced trailing pull queued behind it. The
   * daemon serializes `workspaceFileRead`/`workspaceFileWrite`/`workspaceDiffManifestChunk` pulls on one per-workspace
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
      const transfer = activePatchTransfer;
      activePatchTransfer = undefined;
      if (transfer !== undefined) {
        void bridge.workspaceDiffFileChunkCancel(transfer.scope, {
          manifestID: transfer.manifestID,
          relativePath: transfer.path,
          byteOffset: transfer.byteOffset,
          transferID: transfer.transferID,
        }).catch(() => {});
      }
      const active = activeManifest;
      activeManifest = undefined;
      if (active !== undefined) void bridge.workspaceDiffManifestRelease(active.scope, { manifestID: active.manifestID }).catch(() => {});
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

  function refreshFileListConsumers(): void {
    fileListCache.invalidate();
    quickOpen.refreshListing();
    if (state.mode === "editor") editorSidebar.refreshFilesListing();
  }

  function resubscribeDiffSignature(): void {
    // Only one scope is observed at a time (see SpacesBridge.subscribeDiffSignature's
    // doc comment): replace the previous subscription rather than layering another.
    unsubscribeSignature?.();
    unsubscribeSignature = bridge.subscribeDiffSignature(state.scope, () => {
      void refreshDiff(true, "workspaceChange");
    });
  }

  function dispatch(action: CodePaneAction, configuredBaseScopeRefName?: string): void {
    // This must happen before `renderBody` detaches the old mode's virtualized DOM. The captured
    // lines become the inactive view's durable values until the next time it is visible.
    captureViewPositions();
    const enteringLastCommit = action.type === "setScope" && state.scope.kind !== "lastCommit" && action.scope.kind === "lastCommit";
    if (action.type === "setScope" && diffEditorState !== undefined) hibernateDiffEditorForScopeTransition();
    if (enteringLastCommit) hibernateLastCommitDiffEditor(true);
    if (action.type === "setScope") {
      configuredBaseSelectionToken += 1;
      configuredBaseRefName = configuredBaseScopeRefName;
    }
    state = codePaneReducer(state, action);
    // Last Commit's immutable guard is only meaningful while that scope remains selected. The
    // separate scope-transition guard continues through every comparison until its new patch is
    // complete and has rebuilt the editor's left side.
    if (action.type === "setScope" && state.scope.kind !== "lastCommit") {
      pendingLastCommitDiffEditorRestore = false;
      pendingLastCommitComparisonRebuild = false;
      lastCommitDiffEditorVerified = false;
    }
    toolbar.update(buildToolbarState());

    if (action.type === "setLayout") {
      diffView.setLayout(state.layout);
    } else if (action.type === "setScope") {
      diffLoaded = false;
      // A scope change is a new retry context — `diffRetryFailures`'s climb belongs to
      // the PREVIOUS scope's failure streak. Left unreset, a new scope whose first pull also fails
      // transiently would inherit that climbed count and its first retry could wait up to the 30s cap
      // instead of the 1s floor. Mirrors the Swift host's own reset of its reconnect-failure counters
      // on a scope/path change (CodePaneContentController.swift's diffSignatureReconnectFailures /
      // fileSignatureReconnectFailures), and EditorView.open()'s own reset of externalChangeRetryFailures
      // on a successful open.
      diffRetryFailures = 0;
      // Clear synchronously, before refreshDiff's await can yield control, so the
      // diff area never shows files from a scope other than the toolbar's current pick — a stale
      // diff labeled as the new scope is worse than a loading gap while the fetch is in flight.
      files = [];
      renderChangesList();
      diffView.setLoading();
      comments.setFiles([]);
    }
    renderBody();
    // `setScope` clears DiffView before this point, so the new scope cannot inherit the previous
    // comparison's visible path/line while its replacement manifest is loading.
    pushWorkspaceState();

    if (action.type === "setScope") {
      void refreshDiff(false, "scope");
      resubscribeDiffSignature();
    } else if (action.type === "setMode") {
      // Pushed so a hibernated pane comes back in whichever mode the user last left it in,
      // rather than resetting to the mode it first loaded with — see CodePaneEditorState's
      // unified workspace-state contract in bridge/types.ts.
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
  // that can yield to a teardown. `window.__spacesCollectWorkspaceState` can be called by the Swift
  // host at any moment this
  // pane is torn down — including mid-init, if the user switches away again immediately — and its
  // result is written back under the new page-generation number, which the host's `>=`
  // generation-ordering rule accepts unconditionally. Until this line runs, `EditorView` is still
  // empty, so that flush would return `undefined` and silently overwrite whatever dirty hibernated
  // snapshot the host was holding: a permanent loss of an unsaved edit. `restoreState`'s
  // dirty-restoration branch is pure synchronous computation over the snapshot (no network round
  // trip); only the clean-restoration branch does one `workspaceFileRead` call, an accepted extra
  // cost of moving this earlier. `initPayload.initialMode` already carries the host's live (not
  // original) mode — so a pane that hibernated in Editor mode
  // has already loaded back into Editor mode above; this call is what puts its buffer back too,
  // regardless of which mode ends up on screen.
  await editorView.restoreState(initPayload.workspaceState.editorState ?? undefined);
  editorView.restorePosition(initPayload.workspaceState.editorScrollLine, initPayload.workspaceState.editorFocusedLine);
  const restoredScope = renderMetricScope(state.scope);
  const restoredEditorState = editorView.snapshot();
  afterBrowserPaint(() => {
    // A restored diff may still be queued behind the initial manifest when this milestone fires.
    // DiffView's durable position intentionally retains that logical target until its textual
    // patch renders, so the metric describes the state we restored rather than a transient DOM gap.
    const restoredDiffPosition = state.mode === "diff" ? diffView.durableScrollPosition() : null;
    // `diffSelectedPath` belongs to the diff surface and can remain populated while the restored
    // pane is in Editor mode. In that mode the editor snapshot is the authoritative path.
    const restoredPath = state.mode === "editor"
      ? restoredEditorState?.path
      : restoredDiffPosition?.path ?? diffSelectedPath ?? restoredEditorState?.path;
    bridge.notifyRenderMetric({
      kind: "diff",
      trigger: "workspaceStateRestored",
      elapsedMs: 0,
      fileCount: 0,
      contentBytes: 0,
      mode: state.mode,
      scope: restoredScope,
      layout: state.layout,
      path: restoredPath,
      scrollTop: state.mode === "diff" ? restoredDiffPosition?.line ?? 0 : editorView.visibleLine() ?? 0,
      focusedLine: state.mode === "diff" ? diffView.focusedLineNumber() ?? undefined : editorView.focusedLineNumber() ?? undefined,
      dirty: diffEditorState?.dirty ?? restoredEditorState?.dirty ?? false,
    });
  });
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
  bridge.subscribeFileListSignature(() => {
    // Workspace membership changes are independent of the active diff scope: non-git workspaces
    // have no diff-signature stream at all, and "Last commit" intentionally ignores plain worktree
    // churn. The shared listing cache therefore owns its own workspace-scoped invalidation signal.
    refreshFileListConsumers();
  });
  // Install the one scope listener before an initial manifest starts streaming. A file patch can
  // take arbitrarily long under agent churn; subscribing after that await drops any signature
  // change that arrives in the visible sidebar/placeholder interval.
  resubscribeDiffSignature();
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
  // Workspace-scoped, independent of `state.scope`: the first manifest starts this above so it can
  // overlap patch streaming; this only starts it for panes that have not fetched a manifest yet.
  await loadInitialComments();
}
