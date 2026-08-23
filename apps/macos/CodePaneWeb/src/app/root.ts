import { createBridge } from "../bridge";
import { CodePaneInitPayload, CodePaneThemeChangedEvent, DiffFileEntry, WorkspaceDiffResult } from "../bridge/types";
import { DiffView } from "./diffView";
import { EditorView } from "./editorView";
import { renderFileList } from "./fileList";
import { CodePaneAction, CodePaneState, codePaneReducer, initialState } from "./state";
import { renderToolbar } from "./toolbar";

const INIT_EVENT = "spaces:init";
const THEME_EVENT = "spaces:theme";

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

  const editorContainerEl = document.createElement("div");
  editorContainerEl.className = "diff-area";

  const diffView = new DiffView(diffAreaEl, state.layout);
  const editorView = new EditorView(editorContainerEl, bridge);
  // Wired here (not inside EditorView itself) so the global always reaches this exact instance's
  // live state — see Window.__spacesCollectEditorState's doc comment in bridge/types.ts and
  // EditorView.collectStateForFlush.
  window.__spacesCollectEditorState = () => editorView.collectStateForFlush();

  const toolbar = renderToolbar(
    toolbarHost,
    { mode: state.mode, scope: state.scope, layout: state.layout, baseBranch: initPayload.baseBranch },
    {
      onModeChange: (mode) => dispatch({ type: "setMode", mode }),
      onScopeChange: (scope) => {
        // Belt-and-suspenders alongside the toolbar's own disabled control (see segButton's doc
        // comment): a "vs base branch" scope is unreachable for a workspace with none, so refuse it
        // here too rather than trusting every future caller of onScopeChange to check first.
        if (scope.kind === "baseBranch" && initPayload.baseBranch === undefined) return;
        dispatch({ type: "setScope", scope });
      },
      onLayoutChange: (layout) => dispatch({ type: "setLayout", layout }),
    },
  );

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
   * Pulls the diff for the current scope. A failed pull is swallowed and retried with a bounded
   * exponential backoff (`scheduleDiffRetry`) rather than thrown: the diff-signature push stream
   * dedupes repeat frames end-to-end (both the Swift host's `lastDeliveredSignature` and this
   * app's own `subscribeDiffSignature` listener never re-announce a signature it already told this
   * pane about), so a transient fetch failure here is never retried by anything upstream — if this
   * loop didn't retry, a pull that failed once would never be attempted again until the scope's
   * git state changed again. `token` makes retries latest-wins the same way regular refreshes are:
   * a scope switch (or another refresh) bumps `diffRequestToken`, so a stale retry silently no-ops
   * instead of clobbering whatever the newer attempt already applied.
   */
  async function refreshDiff(preserveScroll: boolean): Promise<void> {
    const token = ++diffRequestToken;
    clearTimeout(diffRetryTimer);
    let result: WorkspaceDiffResult;
    try {
      result = await bridge.workspaceDiff(state.scope);
    } catch {
      if (token !== diffRequestToken) return; // superseded: a newer refresh already won, so this failure is moot
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
    toolbar.update({ mode: state.mode, scope: state.scope, layout: state.layout, baseBranch: initPayload.baseBranch });
    renderBody();

    if (action.type === "setLayout") {
      diffView.setLayout(state.layout);
    } else if (action.type === "setScope") {
      diffLoaded = false;
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
  if (state.mode === "diff") {
    await refreshDiff(false);
  }
  resubscribeDiffSignature();
  // Rehydrate the editor from the host's post-hibernation snapshot. `initPayload.initialMode`
  // already carries the host's live (not original) mode — see the Swift host's `currentMode` —
  // so a pane that hibernated in Editor mode has already loaded back into Editor mode above; this
  // call is what puts its buffer back too, regardless of which mode ends up on screen.
  await editorView.restoreState(initPayload.editorState);
}
