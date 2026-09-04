import { CodeView, parseDiffFromFile } from "@pierre/diffs";
import type { CodeViewItem, FileContents } from "@pierre/diffs";
import { Editor } from "@pierre/diffs/edit";
import { diff3Merge } from "node-diff3";
import {
  CodePaneEditorState,
  SpacesBridge,
  SpacesBridgeError,
  Unsubscribe,
  WorkspaceFileReadResult,
  WorkspaceFileWriteResult,
} from "../bridge/types";
import { CODE_PANE_THEME_NAME, resolveAllowedLanguage } from "../theme";
import { AutosaveScheduler, AutosaveStatus, retryDelayMs, SaveOutcome } from "./autosave";
import { afterBrowserPaint } from "./renderMetrics";

/** Trailing debounce for recovery-state pushes on buffer edits (see `scheduleEditorStatePush`). */
const EDITOR_STATE_DEBOUNCE_MS = 500;
/** A broken editor attach must not leave a frame callback alive for the pane's lifetime. */
const RESTORED_FOCUS_ATTACH_MAX_FRAMES = 120;
export interface EditorViewCallbacks {
  /** Fired exactly when `loadFile()` completes a load that actually replaces the buffer with
   *  `path`'s content: the one seam every real open funnels through. Deliberately NOT fired for a
   *  refused open (`open()`'s flush gate, or `loadFile()`'s own completion-time recheck, when the
   *  buffer that has to be written first is blocked or its write fails), a failed read (the catch
   *  branch), or a superseded load (an `openGeneration` bump already won); see `loadFile`'s own
   *  branches for each. root.ts uses this to record `path` into recents and move the Files-tree
   *  selection (see its `openInEditor`), which is what keeps a refused or failed open from
   *  polluting either. */
  onFileOpened?(path: string): void;
  /** Fires only after CodeView has received the file and the browser has crossed two paint frames,
   *  making it the real-system visible-render endpoint rather than the earlier read completion.
   *  A same-file signature reconcile does not cancel this milestone; only a newer file open does. */
  onFileRendered?(path: string, elapsedMs: number, contentUnits: number): void;
  /** The owning pane folds this snapshot into its one atomic workspace-state document. */
  onStateChanged?(state: CodePaneEditorState | undefined): void;
  /** A discrete editor transition (open/save/external reconciliation) should flush the pane's
   * recovery state immediately. Buffer typing still reaches this only after the editor debounce. */
  onStateTransition?(): void;
}

/**
 * Runs a 3-way line merge via `node-diff3`'s `diff3Merge` — never `merge`/`mergeDiff3`/
 * `mergeDigIn`, which splice `<<<<<<<`/`=======`/`>>>>>>>` marker text into the returned result:
 * the auto-merge case must never write conflict markers into the user's buffer, only either a
 * clean merged buffer or a decision that this isn't auto-mergeable at all.
 *
 * Inputs are split on `"\n"` rather than left to `diff3Merge`'s default whitespace splitting: a
 * source file's merge needs line granularity ("non-overlapping edits" per the locked UX means
 * non-overlapping *lines*), not token granularity. Splitting and rejoining on `"\n"` round-trips
 * exactly whenever nothing conflicts (`s.split("\n").join("\n") === s` always holds), so a clean
 * merge never mangles line endings it didn't touch.
 *
 * Any conflicting region — even just one — makes the whole result a conflict: this only ever backs
 * the non-overlapping-edits case (see `EditorView.handleExternalChange`), so a partially-applied
 * merge is never shown to the user.
 */
export function diff3MergeLines(mine: string, base: string, theirs: string): { merged: string } | { conflict: true } {
  const regions = diff3Merge(mine.split("\n"), base.split("\n"), theirs.split("\n"));
  const merged: string[] = [];
  for (const region of regions) {
    if (region.conflict) return { conflict: true };
    if (region.ok) merged.push(...region.ok);
  }
  return { merged: merged.join("\n") };
}

/** The chip's wording for each save state (docs/spec.md's Editor section owns this copy). The failed
 *  state names both the reason and when the scheduler retries on its own, since the "Retry now"
 *  action beside it only skips that wait. */
function saveStatusText(status: AutosaveStatus): string {
  switch (status.kind) {
    case "idle":
      return "";
    case "dirty":
      return "Unsaved";
    case "saving":
      return "Saving…";
    case "saved":
      return "Saved";
    case "failed":
      return `Save failed: ${status.reason} · retry in ${Math.round(status.retryInMs / 1000)} s`;
    case "blocked":
      return `Save blocked: ${status.reason}`;
  }
}

/**
 * Editor mode: a single-file `@pierre/diffs` `CodeView` in edit mode, saved through the CAS
 * `workspaceFileWrite` call. This class owns no file-picking UI of its own — every file this view
 * shows arrives via its public `open()`, called by root.ts from the ⌘P quick-open overlay, Editor
 * mode's Files tree, or the Changes list (see quickOpen.ts/editorSidebar.ts/README.md's "Editor
 * mode" section for the three entry points and how root.ts routes between them). The top bar this
 * view renders is just the open file's path (or a "⌘P to open a file" hint when none is open) and
 * the autosave status chip.
 *
 * Saving is automatic: every buffer edit notes itself with an `AutosaveScheduler` (autosave.ts),
 * which coalesces a burst of keystrokes into one CAS write, never overlaps two writes, backs off on
 * a failed write, and stops writing while this view reports a block only the user can clear. This
 * class supplies that scheduler's whole view of the world through the `AutosaveHost` methods below
 * (`isDirty`/`blockedReason`/`performSave`) and paints its status into the top bar's chip.
 *
 * External-change handling (disk changing under an open file) is a single shared path,
 * `handleExternalChange`, driven by two triggers — a `spaces:fileSignature` push event and a
 * `performSave()` CAS rejection, implementing four cases:
 *   - clean buffer + disk changed: silently reload, adopt the new baseline.
 *   - clean buffer + file deleted: swap in a "deleted on disk" placeholder.
 *   - dirty buffer + disk changed, non-overlapping edits: auto-merge via `diff3MergeLines`, with a
 *     dismissible "Merged external changes" indicator offering Undo.
 *   - dirty buffer + disk changed, overlapping edits (or Undo of an auto-merge) + dirty buffer with
 *     the file deleted: conflict state, which blocks autosave and shows a read-only compare view
 *     (buffer vs. disk) with "Keep mine" / "Take disk" (or "Close without saving" when deleted)
 *     actions.
 *
 * Every open/edit/save/external-change transition updates the unified workspace recovery document
 * through root's callback, so this view's state can be rebuilt after a hibernation cycle.
 */
export class EditorView {
  private readonly bridge: SpacesBridge;
  /** The top bar's path display — the open file's path, or the "⌘P to open a file" hint when none
   *  is open (Design O; see this class's doc comment). Not an input: there is nothing to type into
   *  it, only to read. */
  private readonly pathLabel: HTMLElement;
  /** The top bar's autosave status pill: the one place a save's state is reported (see
   *  `renderSaveStatus`). There is no Save button anywhere in Editor mode. */
  private readonly saveStatusChip: HTMLElement;
  /** Shown only while a write has failed and the scheduler is counting down to its own retry;
   *  clicking it runs that retry immediately instead of waiting out the backoff. */
  private readonly retrySaveBtn: HTMLButtonElement;
  private readonly scheduler: AutosaveScheduler;
  private readonly codeHost: HTMLElement;
  private readonly banner: HTMLElement;
  private codeView: CodeView | undefined;

  private currentPath: string | undefined;
  private baseSHA256: string | undefined;
  /** The content at the current CAS baseline (`baseSHA256`) — i.e. what's on disk as of the last
   *  open/save/external-change. This is diff3's "base"/"o" side and the conflict compare view's
   *  disk side; kept distinct from `latestContent` (the live buffer, diff3's "mine"/"a" side). */
  private baseContent: string | undefined;
  private latestContent: string | undefined;
  /** True from the first edit after an open/restore/save until the next successful save. The
   *  recovery document records it so rehydration knows whether the buffer can be trusted over
   *  disk (see `restoreState`). */
  private dirty = false;
  private conflict = false;
  /** True iff the current conflict is a "deleted on disk" one rather than a "changed on disk" one —
   *  governs the compare view's wording and the "Take disk"/"Close without saving" button label and
   *  behavior. Deliberately NOT part of `CodePaneEditorState`: a rehydrated conflict always shows
   *  the "changed" wording (see `restoreState`'s doc comment), so this always starts `false` and is
   *  only ever set by `enterConflictState` within a live session. */
  private diskMissing = false;
  /** The CAS target an explicit "Keep mine" confirmed, mirroring `CodePaneEditorState`'s field of
   *  the same name (see it for why the decision has to be durable). Editor mode only ever records
   *  the deleted case, `null` = create-if-missing: every other Keep mine confirms a real disk hash,
   *  which `baseSHA256` already carries and a fresh read reproduces, while a file that is still
   *  missing would otherwise re-derive a deleted-file conflict from every reconcile and ask the user
   *  to confirm the same deletion again. */
  private confirmedBaseSHA256: string | null | undefined;
  /** The buffer's content immediately before a diff3 auto-merge was applied, kept to offer "Undo"
   *  on the merge indicator. A merged buffer is dirty, so autosave writes it within the debounce
   *  window; that write deliberately does NOT retire the offer, because the merge result reaching
   *  disk is exactly the state the offer exists to undo. Cleared (and the indicator hidden) the
   *  moment any of: another edit lands on top of the merge (undo would silently discard it), an
   *  external change replaces the buffer, a new file is opened, or a real conflict is entered.
   *  Deliberately NOT part of
   *  `CodePaneEditorState` (see its doc comment) — a hibernation cycle simply drops the Undo offer,
   *  which is an accepted, cheap-to-lose affordance rather than a data-loss risk. */
  private pendingMergeUndo: string | undefined;
  private editGeneration = 0;
  /** Bumped at the start of every `loadFile()` call; a call whose token has been superseded by a
   *  later `loadFile()` drops its result (success or failure) instead of clobbering whatever that
   *  later call already loaded. Same latest-wins shape as `root.ts`'s `diffRequestToken`. */
  private openGeneration = 0;
  /** Bumped by every `open()` call, before it waits on the flush that has to land first, and by a
   *  re-pick of the file already open (which loads nothing). Every step of `loadFile` that runs after
   *  an await is guarded by it and by nothing else. Separate from `openGeneration` on purpose: this
   *  says "a newer open has claimed this pane", which is what makes an earlier open drop its load
   *  once its own flush or read resolves, while `openGeneration` says
   *  "the buffer has actually been replaced", which is what a settling write checks before adopting
   *  a baseline. Conflating them would make an in-flight write stand down for an open that has not
   *  replaced anything yet, leaving the buffer dirty against a baseline the write already moved. */
  private openRequestGeneration = 0;
  /** Bumped at the start of every `handleExternalChange` fetch; a fetch superseded by a later one
   *  (two external-change triggers arriving close together) drops its result — same latest-wins
   *  shape as `openGeneration`, but scoped to this one flow since it must survive within a single
   *  `loadFile()` generation (a save-conflict retry and a live signature event can race each other
   *  without either implying a new file was opened). */
  private externalChangeFetchToken = 0;
  /** Consecutive-failure counter and pending-timer handle for `handleExternalChange`'s
   *  execution-failure retry (see its catch branch and `scheduleExternalChangeRetry`) — same
   *  floor/doubling/cap backoff shape as root.ts's `diffRetryFailures`/`diffRetryTimer`. Reset to 0
   *  whenever a `handleExternalChange` run reaches a decoded outcome (a successful read or an
   *  authoritative `notFound`) or by a successful `loadFile()`; the pending timer is
   *  additionally cleared at the very top of every `handleExternalChange` call (see its doc
   *  comment), so a fresh trigger (a live signature event or `performSave()`'s CAS-conflict arm)
   *  supersedes whatever retry was pending without needing a separate reset path. */
  private externalChangeRetryFailures = 0;
  private externalChangeRetryTimer: ReturnType<typeof setTimeout> | undefined;
  /** True for the duration of one `performSave()` call. The scheduler already guarantees it never
   *  starts a second write while one is in flight; this flag keeps that invariant true for the one
   *  write that does not come from the scheduler's loop, since two overlapping CAS writes racing the
   *  same baseline would let the second silently win with a hash the first's in-flight write
   *  invalidates. */
  private saveInFlight = false;
  /** The exact content an in-flight `performSave()` submitted, set just before the write await and cleared
   *  in `performSave()`'s `finally`. Exists ONLY so `handleExternalChange` can recognize disk content that
   *  is this pane's own in-flight write when `latestContent` has already moved past it — the
   *  `disk.content === this.latestContent` branch above it covers the not-moved-on case (see that
   *  branch's own comment for the full mechanism). */
  private pendingSaveSubmitted: string | undefined;
  /** True exactly while `this.banner` is showing the `invalidArgument` "file can no longer be
   *  displayed" error from `handleExternalChange`'s catch branch — not the merge indicator, the
   *  discard-consent prompt, the conflict compare view, or any other banner use, all of which use
   *  the same DOM element but set this flag themselves. Set `true` where that error is shown; the
   *  next `handleExternalChange` run that reaches a decoded outcome (a successful read or an
   *  authoritative `notFound`) clears the flag and hides the banner before branching on the read
   *  result, since a file that was unreadable a moment ago may now be exactly back at the baseline
   *  (the same-hash early return) or freshly readable (the clean-buffer silent reload) — either way
   *  the stale error must not linger over a file that reads fine again. Gating the clear on this
   *  flag (rather than clearing unconditionally on every decoded outcome) is what stops a spurious
   *  same-hash dedupe event from wiping out an unrelated banner it did not put up, in particular the
   *  merge indicator `showMergeIndicator` shows on the same element.
   *
   *  Deliberately NOT part of `CodePaneEditorState` (mirrors `pendingMergeUndo`'s doc comment): a
   *  hibernation restore's `restoreState` re-runs `handleExternalChange`, which re-derives this from
   *  scratch — a still-unreadable file re-enters the catch and re-shows the banner on its own, and a
   *  now-readable file heals through the normal decoded-outcome path either way, so nothing is lost
   *  by not carrying this flag across the snapshot.
   *
   *  Round-24 Fix 3 (P2): also cleared by `loadFile()`'s own success arm — a switch to a different
   *  file must not carry this flag forward into that file's first `handleExternalChange` reconcile,
   *  which would otherwise clear it AND hide whatever unrelated banner (discard consent, merge
   *  indicator) that file has put up in the meantime. */
  private unreadableBannerVisible = false;
  private editorStatePushTimer: ReturnType<typeof setTimeout> | undefined;
  private focusedLine: number | null = null;
  /** Invalidates a pending restored-caret poll whenever a different editor document renders. */
  private focusRestoreGeneration = 0;
  /** Unsubscribes the previous `subscribeFileSignature` listener; replaced (not layered) every time
   *  a new path becomes "the currently open file" — see `subscribeToFileSignature`. */
  private fileSignatureUnsubscribe: Unsubscribe | undefined;
  /** Set by `dispose()`; see its doc comment for what this guards that a token bump cannot. */
  private disposed = false;

  constructor(
    container: HTMLElement,
    bridge: SpacesBridge,
    private readonly callbacks: EditorViewCallbacks = {},
  ) {
    this.bridge = bridge;

    const openBar = document.createElement("div");
    openBar.className = "editor-open-bar";

    this.pathLabel = document.createElement("span");
    this.pathLabel.className = "editor-path";
    this.setPathLabel(undefined);
    openBar.appendChild(this.pathLabel);

    this.saveStatusChip = document.createElement("span");
    this.saveStatusChip.className = "save-status";
    this.saveStatusChip.id = "code-pane-editor-save-status";
    openBar.appendChild(this.saveStatusChip);

    this.retrySaveBtn = document.createElement("button");
    this.retrySaveBtn.type = "button";
    this.retrySaveBtn.className = "btn ghost";
    this.retrySaveBtn.id = "code-pane-editor-retry-save";
    this.retrySaveBtn.textContent = "Retry now";
    this.retrySaveBtn.addEventListener("click", () => void this.scheduler.flush());
    openBar.appendChild(this.retrySaveBtn);

    this.scheduler = new AutosaveScheduler({
      isDirty: () => this.dirty,
      blockedReason: () => this.blockedReason(),
      performSave: () => this.performSave(),
      onStatus: (status) => this.renderSaveStatus(status),
    });
    this.renderSaveStatus(this.scheduler.status);

    const codeArea = document.createElement("div");
    codeArea.className = "diff-area";
    codeArea.style.position = "relative";

    // The CodeView mounts on this inner child, not on `.diff-area` itself, for the same
    // reason diffView.ts mounts on its own `.diff-view-root`: the element handed to
    // `CodeView.setup()` must be a bounded-height scroll container (see that class's CSS
    // comment in app.css), and making the outer `.diff-area` scroll would carry the
    // absolutely-positioned `.banner` away with the content instead of keeping it docked.
    this.codeHost = document.createElement("div");
    this.codeHost.className = "diff-view-root";
    this.codeHost.id = "code-pane-editor-scroll";
    codeArea.appendChild(this.codeHost);

    this.banner = document.createElement("div");
    this.banner.className = "banner conflict";
    this.banner.style.display = "none";
    codeArea.appendChild(this.banner);

    container.appendChild(openBar);
    container.appendChild(codeArea);
  }

  /** Sets the top bar's path display: the open file's path, or the "⌘P to open a file" hint when
   *  none is open (Design O). */
  private setPathLabel(path: string | undefined): void {
    this.pathLabel.textContent = path ?? "⌘P to open a file";
    this.pathLabel.classList.toggle("hint", path === undefined);
  }

  /** Builds (once) or returns the shared `CodeView` instance backing both this view's edit-mode
   *  buffer and its read-only conflict compare view — see `CodeViewItem`'s discriminated union,
   *  where a `"file"` (edit-capable) item and a `"diff"` (read-only) item are equally valid on the
   *  same instance via `setItems`. One instance is reused rather than standing up a second `CodeView`
   *  for the compare view: the two states are mutually exclusive (never shown at once), so a second
   *  instance would only double the setup/teardown cost and the virtualizer/highlighter warm-up
   *  for no benefit. */
  private ensureCodeView(): CodeView {
    if (!this.codeView) {
      this.codeView = new CodeView({
        theme: CODE_PANE_THEME_NAME,
        createEditor: (options) => new Editor(options),
        onItemEditChange: (_item, file) => {
          this.latestContent = file.contents;
          this.dirty = true;
          this.focusedLine = this.readFocusedLine() ?? this.focusedLine;
          // The keystroke seam: one debounced write per burst of typing, arranged by the scheduler.
          this.scheduler.noteEdit();
          // A merge indicator's Undo only makes sense against the exact pre-merge buffer: an edit
          // made on top of the merge result would be silently discarded by an Undo that reverts to
          // that snapshot, so any further edit retires the offer instead of leaving it live.
          if (this.pendingMergeUndo !== undefined) {
            this.pendingMergeUndo = undefined;
            this.banner.style.display = "none";
          }
          this.scheduleEditorStatePush();
        },
      });
      this.codeView.setup(this.codeHost);
    }
    return this.codeView;
  }

  /** Builds a fresh single-file edit-mode item into the shared `CodeView`. Shared by `loadFile()` (disk
   *  content), `restoreState()`'s dirty branch (a rehydrated buffer that must NOT be re-read from
   *  disk), and `handleExternalChange`'s reload/auto-merge branches, so none of those paths can
   *  drift apart on how the buffer is (re)loaded. */
  private loadIntoCodeView(path: string, content: string): void {
    const codeView = this.ensureCodeView();
    this.focusRestoreGeneration += 1;
    this.editGeneration += 1;
    const item: CodeViewItem = {
      id: path,
      type: "file",
      // Forced explicitly rather than left to auto-detection; see
      // theme/index.ts's resolveAllowedLanguage doc comment.
      file: { name: path, contents: content, cacheKey: path, lang: resolveAllowedLanguage(path) },
      edit: true,
      version: this.editGeneration,
    };
    codeView.setItems([item]);
    this.completeEditorAttach(codeView, item);
  }

  /**
   * Works around an attach-order gap in `@pierre/diffs` for items born with `edit: true`: the
   * render loop renders the item first (editor still null, so `File.render` skips its
   * `syncRenderViewToEditor` call) and only then attaches the editor — whose own attach path
   * (`File.attachEditor`) syncs immediately only when `editorRenderReady()` already holds, which
   * it never does on that first pass (the highlight result hasn't landed, and once the edit
   * session is active `onHighlightSuccess` drops it without triggering a re-render). Nothing
   * re-renders a single always-visible item after that, so the editor never takes over the DOM:
   * the file stays a static, non-editable `PRE` forever.
   *
   * The escape is one forced full re-render AFTER the editor has attached: a version-bumped
   * `updateItem` marks the item render-dirty, and that render's `File.render` sees a non-null
   * editor and runs `syncRenderViewToEditor`, completing the takeover (contenteditable, caret,
   * key handling). Attach completion has no callback, so poll `getEditor` across frames, guarded
   * by `editGeneration` so a newer load (or the conflict compare view) supersedes the poll.
   * For reloads of an already-attached editor the poll resolves on the first frame and the extra
   * re-render is a cheap no-op on top of the sync the forced render already performs.
   */
  private completeEditorAttach(codeView: CodeView, item: CodeViewItem): void {
    const generation = this.editGeneration;
    const poll = () => {
      if (generation !== this.editGeneration) return; // a newer load owns the CodeView now
      if (codeView.getEditor(item.id) === undefined) {
        requestAnimationFrame(poll);
        return;
      }
      this.editGeneration += 1;
      codeView.updateItem({ ...item, version: this.editGeneration });
      this.assignEditorIdentifierAfterRender(item.id, this.editGeneration);
    };
    requestAnimationFrame(poll);
  }

  private assignEditorIdentifierAfterRender(path: string, generation: number, framesRemaining = 2): void {
    if (this.currentPath !== path || generation !== this.editGeneration || !this.codeView) return;
    if (this.assignEditorIdentifier()) return;
    if (framesRemaining === 0) return;
    // Pierre creates the semantic editor surface in an open shadow root during the render pass
    // scheduled by updateItem. Retry only across that bounded render window; a superseding open
    // invalidates the generation and stops this callback from touching the new document.
    requestAnimationFrame(() => this.assignEditorIdentifierAfterRender(path, generation, framesRemaining - 1));
  }

  private assignEditorIdentifier(): boolean {
    const editorElement = this.renderedElements<HTMLElement>('[role="textbox"][aria-multiline="true"]')[0];
    if (!editorElement) return false;
    editorElement.id = "code-pane-editor-input";
    return true;
  }

  /** Logical source-line recovery avoids retaining a stale pixel offset after virtualization. */
  visibleLine(): number | null {
    if (!this.codeHost.isConnected) return null;
    const top = this.codeHost.getBoundingClientRect().top;
    for (const node of this.renderedElements<HTMLElement>("[data-line]")) {
      if (node.getBoundingClientRect().bottom <= top) continue;
      const line = Number(node.dataset.line);
      if (Number.isInteger(line) && line > 0) return line;
    }
    return null;
  }

  focusedLineNumber(): number | null {
    // Caret movement is not an edit, so it does not flow through `onItemEditChange`. Sampling the
    // live selection at the snapshot seam preserves keyboard/mouse navigation without attaching
    // high-frequency global selection listeners to every editor document.
    this.focusedLine = this.readFocusedLine() ?? this.focusedLine;
    return this.focusedLine;
  }

  restorePosition(scrollLine: number | null | undefined, focusedLine: number | null | undefined): void {
    this.focusedLine = focusedLine ?? null;
    if (!this.currentPath) return;
    if (scrollLine !== null && scrollLine !== undefined) {
      this.codeView?.scrollTo({ type: "line", id: this.currentPath, lineNumber: scrollLine, behavior: "instant" });
      this.codeHost.dataset.scrollLine = String(scrollLine);
    }
    if (focusedLine !== null && focusedLine !== undefined) {
      // Conflict and deleted-file states deliberately render non-editable CodeView items. There is
      // no caret to restore there, so polling `getEditor` would spin forever instead of waiting for
      // a future user action that returns to an editable document.
      if (this.conflict || this.latestContent === undefined) return;
      const path = this.currentPath;
      const restoreGeneration = ++this.focusRestoreGeneration;
      let remainingAttachFrames = RESTORED_FOCUS_ATTACH_MAX_FRAMES;
      const focusWhenAttached = () => {
        if (
          restoreGeneration !== this.focusRestoreGeneration ||
          this.currentPath !== path ||
          this.conflict ||
          this.latestContent === undefined
        ) return;
        const editor = this.codeView?.getEditor(path) as { focus?(options: { lineNumber: number }): void } | undefined;
        if (editor === undefined) {
          if (remainingAttachFrames === 0) return;
          remainingAttachFrames -= 1;
          requestAnimationFrame(focusWhenAttached);
          return;
        }
        editor.focus?.({ lineNumber: focusedLine });
      };
      requestAnimationFrame(focusWhenAttached);
    }
  }

  private readFocusedLine(): number | null {
    // Pierre keeps the canonical caret in its editor model. Reading that model is important for its
    // shadow-root editor: WebKit's document Selection can be empty while the editor still has a
    // focused logical selection, which would otherwise lose the focused line on a workspace switch.
    if (this.currentPath !== undefined) {
      const editor = this.codeView?.getEditor(this.currentPath) as {
        getState?: () => { selections?: Array<{ start: { line: number }; end: { line: number }; direction?: number }> };
      } | undefined;
      const selection = editor?.getState?.().selections?.at(-1);
      if (selection !== undefined) {
        const caret = selection.direction === -1 ? selection.start : selection.end;
        if (Number.isInteger(caret.line) && caret.line >= 0) return caret.line + 1;
      }
    }
    return null;
  }

  /**
   * Pierre mounts each editor in an open `diffs-container` shadow root. Traverse open roots so
   * editor identity and recovery sampling observe the real rendered surface as well as the
   * light-DOM root used by tests and host layout.
   */
  private renderedElements<T extends Element>(selector: string, root: HTMLElement = this.codeHost): T[] {
    const roots: ParentNode[] = [];
    const visit = (renderRoot: ParentNode): void => {
      roots.push(renderRoot);
      for (const element of renderRoot.querySelectorAll<HTMLElement>("*")) {
        if (element.shadowRoot !== null) visit(element.shadowRoot);
      }
    };
    visit(root.shadowRoot ?? root);
    return roots.flatMap((renderRoot) => [...renderRoot.querySelectorAll<T>(selector)]);
  }

  /**
   * Public entry point for every way a file can be opened in Editor mode: the ⌘P quick-open
   * overlay, the Files tree, and the Changes list (see this class's doc comment) all call this and
   * nothing else.
   *
   * Opening another file while the current buffer has unsaved edits writes them first and only then
   * loads the new file, which is what keeps the spec's promise that an edit is never discarded by an
   * open. A flush that ends blocked (a standing conflict, which only "Keep mine" / "Take disk" can
   * clear) or failed refuses the open and says why, leaving the current buffer exactly where it is.
   */
  async open(path: string): Promise<void> {
    // Claimed BEFORE anything else, the same-path return below included: a second open arriving
    // while an earlier one is still waiting on its flush supersedes it, so the earlier open drops
    // its own load instead of replacing the buffer the newer open is about to fill. Re-picking the
    // currently-open file is just as much a claim on the pane as picking a different one: it is the
    // user's latest selection, so a pending open of some other file must stand down rather than
    // swap that file in once its flush settles.
    const request = ++this.openRequestGeneration;
    // Re-picking the file already open (its own row in Files/Changes, or ⌘P again) must not fall
    // into the flush gate below: the file is already on screen, so there is nothing to open that
    // isn't already showing, and re-reading disk would destroy the very edits the flush is trying to
    // protect. A standing conflict is dirty by construction and never clears `currentPath`, so
    // re-picking the same path mid-conflict also lands here and just stays put.
    if (path === this.currentPath && this.dirty) return;
    if (this.dirty && this.currentPath !== undefined) {
      const outcome = await this.scheduler.flush();
      if (request !== this.openRequestGeneration) return; // a later open() already won
      if (outcome === "failed") {
        this.showSaveIssueBanner();
        return;
      }
      // A blocked flush is a standing conflict, and the conflict compare view on screen holds the
      // only two controls that can clear it. Its reason is already on the chip ("Save blocked: ..."),
      // so the refusal says nothing more rather than replacing those controls with plain text.
      if (outcome === "blocked") return;
    }
    await this.loadFile(path, request);
  }

  /** ⌘S and the host's teardown flush: writes any pending edit immediately instead of waiting out
   *  the debounce, and reports what the buffer ended up as. */
  flushNow(): Promise<"clean" | "blocked" | "failed"> {
    return this.scheduler.flush();
  }

  /** The autosave state the top bar's chip is showing. */
  saveStatus(): AutosaveStatus {
    return this.scheduler.status;
  }

  /**
   * Pane teardown: once this returns the view schedules nothing further, holds no subscription, and
   * never calls back into the host again. Beyond the explicit cancels, every latest-wins token the
   * view owns is bumped, which is what makes the work already in flight stand down at the guard it
   * already has rather than growing a teardown branch of its own: a load mid-read
   * (`openRequestGeneration`, which `loadFile` alone answers to, with `openGeneration` bumped
   * alongside it for the writes and reconciles that answer to that one), a reconcile mid-fetch
   * (`externalChangeFetchToken`), and the requestAnimationFrame polls that
   * complete an editor attach or restore focus (`editGeneration`, `focusRestoreGeneration`).
   * `disposed` covers the two entry points a token cannot reach: a signature event that beat the
   * unsubscribe, and the continuation of a write that was already in flight.
   */
  dispose(): void {
    this.disposed = true;
    this.scheduler.cancel();
    this.fileSignatureUnsubscribe?.();
    this.fileSignatureUnsubscribe = undefined;
    clearTimeout(this.externalChangeRetryTimer);
    clearTimeout(this.editorStatePushTimer);
    this.openRequestGeneration += 1;
    this.openGeneration += 1;
    this.externalChangeFetchToken += 1;
    this.editGeneration += 1;
    this.focusRestoreGeneration += 1;
  }

  /** Paints the top bar's chip, the single surface for save state (Option C). Idle is the absence of
   *  the chip: a file nobody has typed into has nothing to report. The "Retry now" action rides
   *  alongside the failed state only, since it is the only state with a wait to skip. */
  private renderSaveStatus(status: AutosaveStatus): void {
    this.saveStatusChip.dataset.state = status.kind;
    this.saveStatusChip.textContent = saveStatusText(status);
    this.saveStatusChip.style.display = status.kind === "idle" ? "none" : "inline-flex";
    this.retrySaveBtn.style.display = status.kind === "failed" ? "inline-flex" : "none";
  }

  /** The scheduler's `blockedReason`: what stops this view from writing at all until the user
   *  resolves it. `diskMissing` is only ever set alongside `conflict` (see `enterConflictState`), so
   *  it is checked first to give the deleted case its own wording. */
  private blockedReason(): string | undefined {
    if (this.diskMissing) return "File deleted on disk";
    if (this.conflict) return "File changed on disk";
    return undefined;
  }

  /** The refusal notice for an open whose mandatory flush failed. Only the `failed` outcome reaches
   *  here (a block keeps its own compare view on screen), and the chip's wording for that failure is
   *  exactly the reason to show. */
  private showSaveIssueBanner(): void {
    this.banner.className = "banner error";
    this.banner.textContent = saveStatusText(this.scheduler.status);
    this.banner.style.display = "flex";
  }

  /**
   * `request` is the `openRequestGeneration` token its caller in `open()` claimed the pane with, and
   * it is the only thing every step after an await here is guarded by. It is the request token
   * rather than `openGeneration` because the two answer different questions: `openGeneration` says
   * "the buffer has actually been replaced", which is what an in-flight write or reconcile checks
   * before adopting anything, while the token says "this open is still the user's latest selection",
   * which is the only thing that decides whether this load may proceed. Re-picking the file already
   * open claims the pane without loading anything, so it moves the token and not `openGeneration`,
   * and a load already in flight for some other file has to stand down on it.
   */
  private async loadFile(path: string, request: number): Promise<void> {
    const renderStartedAt = performance.now();
    this.openGeneration += 1;
    let result: WorkspaceFileReadResult;
    try {
      result = await this.bridge.workspaceFileRead(path, "editor");
    } catch (err) {
      if (request !== this.openRequestGeneration) return; // a later open() already claimed the pane
      const message = err instanceof SpacesBridgeError ? err.message : "Failed to open file.";
      this.banner.className = "banner error";
      this.banner.textContent = message;
      this.banner.style.display = "flex";
      // A failed open leaves the previously-open file (if any) fully displayed but its own pending
      // external-change reconcile — if one was in flight — was just discarded by the `openGeneration`
      // bump above. Fire a fresh one for it: `handleExternalChange` captures the CURRENT generation and
      // a fresh fetch token at its own entry, so this reconcile is first-class, not itself discarded by
      // the very bump that stranded the previous one. If disk didn't actually change, this is a no-op
      // extra read; if it did, this is the only thing that will ever catch it (see
      // `CodePaneContentController.swift`'s `restoreFileSignatureMonitoringAfterFailedOpen` doc comment
      // for the paired Swift-side reasoning).
      if (this.currentPath !== undefined) void this.handleExternalChange();
      return; // leave the previous file's path label as-is; the failed target was never adopted
    }
    if (request !== this.openRequestGeneration) return; // a later open() already claimed the pane
    if (this.dirty && this.currentPath !== undefined) {
      // The buffer went dirty WHILE this read was in flight: the user typing into the currently-open
      // file during the seconds a remote read can take. `open()`'s own flush ran before the read
      // started and cannot see those edits, so this is the only place that can. Edits belong to the
      // file they were typed into, so they are written before the swap rather than carried into it.
      const outcome = await this.scheduler.flush();
      if (request !== this.openRequestGeneration) return; // a later open() already claimed the pane
      if (outcome !== "clean") {
        // Only a failure needs saying: a block already owns the banner with the compare view that
        // resolves it, and the chip carries its reason (see `open()`'s own refusal).
        if (outcome === "failed") this.showSaveIssueBanner();
        // Same reconcile as the catch block above, for the same reason: this refusal leaves the
        // previously-open file current, and any of its own in-flight reconcile was just discarded by
        // the generation bump. This also repairs a Swift-side wrinkle: the successful read for `path`
        // already retargeted the device's file-signature subscription to `path`, so this reconcile's
        // own `workspaceFileRead(this.currentPath)` reaches Swift as a path change and its success arm
        // resubscribes the signature stream back to `this.currentPath` as a byproduct.
        void this.handleExternalChange();
        return;
      }
    }
    this.setPathLabel(path);
    this.currentPath = path;
    this.baseSHA256 = result.sha256;
    this.baseContent = result.content;
    this.latestContent = result.content;
    this.dirty = false;
    this.conflict = false;
    this.diskMissing = false;
    this.confirmedBaseSHA256 = undefined;
    this.pendingMergeUndo = undefined;
    this.banner.style.display = "none";
    // Fix 3 (round-24, P2): the flag scopes an unreadable-file error banner to the file that raised
    // it (see the flag's own doc comment). A successful open establishes a fresh file context, so it
    // must not leak into the next file's first decoded `handleExternalChange` reconcile, whose
    // unconditional-on-this-flag clear would otherwise hide an unrelated banner (the merge
    // indicator, say) that file put up, using state left over from a DIFFERENT file.
    this.unreadableBannerVisible = false;
    // A successful open establishes a fresh file context: any execution-failure retry still
    // pending for the PREVIOUS file is already neutralized by the `openGeneration` bump above (its
    // fire-time check no-ops), but clearing it here too avoids a dangling timer and lets this new
    // file's own retry backoff (if it ever needs one) start at the floor.
    clearTimeout(this.externalChangeRetryTimer);
    this.externalChangeRetryFailures = 0;
    // Every part of the scheduler's state describes the file being replaced here: its "Saved" is not
    // true of this one (which has never been edited), and its backoff is not this one's to inherit.
    // After the flush above, so the previous file's own pending write is never dropped by this.
    this.scheduler.reset();

    this.loadIntoCodeView(path, result.content);
    afterBrowserPaint(() => {
      if (request !== this.openRequestGeneration || this.currentPath !== path) return;
      this.callbacks.onFileRendered?.(path, Math.max(performance.now() - renderStartedAt, 0), result.content.length);
    });
    this.subscribeToFileSignature(path);
    // Immediate, not debounced: a file open is a discrete transition, not a buffer edit.
    this.pushEditorStateNow();
    // The one place a load actually completes (see `EditorViewCallbacks.onFileOpened`'s doc
    // comment): every earlier return in this method (the catch branch, the flush refusal, the
    // generation checks) skips this line, which is what keeps a refused or failed open from firing
    // it.
    this.callbacks.onFileOpened?.(path);
  }

  /** (Re)points the one live `spaces:fileSignature` stream at `path`, replacing rather than
   *  layering on top of the previous subscription — mirrors `root.ts`'s `resubscribeDiffSignature`,
   *  and the same one-scope-at-a-time model `SpacesBridge.subscribeFileSignature`'s doc comment
   *  describes. A stray event for a path this pane has since navigated away from (a slow unsubscribe
   *  racing a fast reopen) is filtered by the `event.path !== this.currentPath` check rather than
   *  relied upon to never happen. */
  private subscribeToFileSignature(path: string): void {
    this.fileSignatureUnsubscribe?.();
    this.fileSignatureUnsubscribe = this.bridge.subscribeFileSignature(path, (event) => {
      if (event.path !== this.currentPath) return;
      void this.handleExternalChange();
    });
  }

  /**
   * The one shared handler for "disk changed under the open file", called both by the
   * file-signature listener above (a push event) and by `performSave()`'s CAS-conflict arm (a rejected
   * write is itself evidence disk moved). Always does its own fresh `workspaceFileRead` rather than
   * trusting whatever triggered it: a `FileSignatureEvent` is deliberately just a "go look" signal
   * with no content payload (see its doc comment), and a save conflict's `currentSHA256` can already
   * be stale again by the time this runs if anything else touched disk since.
   *
   * Implements the locked 4-case UX (see this class's doc comment). Runs unchanged while already in
   * conflict (e.g. a second external change arriving before the first is resolved, or "Keep mine"
   * itself hitting a fresh conflict — see `resolveConflictKeepMine`): `this.latestContent` is frozen
   * while `this.conflict` is true (the compare view's `CodeView` item isn't in edit mode, so nothing
   * calls `onItemEditChange`) and `this.baseContent` still holds the disk snapshot from the standing
   * conflict's entry, so the same diff3 decision below naturally re-runs against the newest disk
   * state — there is no separate "already conflicted" branch to maintain.
   */
  private async handleExternalChange(): Promise<void> {
    if (this.disposed) return; // a signature event racing the unsubscribe, or a settling write's conflict arm
    const path = this.currentPath;
    if (!path) return; // no open file — a stray/late event after the pane moved on
    const generation = this.openGeneration;
    const fetchToken = ++this.externalChangeFetchToken;
    // Cancel any pending execution-failure retry: this call — whichever of the three triggers
    // (a live signature event, save()'s CAS-conflict arm, or the retry's own scheduled fire) caused
    // it — is itself a fresh attempt that supersedes whatever the timer was going to redo, mirroring
    // root.ts's `clearTimeout(diffRetryTimer)` at the very top of its own `refreshDiff`.
    clearTimeout(this.externalChangeRetryTimer);

    let disk: { content: string; sha256: string } | undefined;
    try {
      const result = await this.bridge.workspaceFileRead(path, "editor");
      disk = { content: result.content, sha256: result.sha256 };
    } catch (err) {
      // Superseded before this failure even landed (a newer loadFile() or a newer external-change fetch
      // already started) — nothing below would matter, including scheduling a retry for content
      // nobody is looking at anymore. Mirrors root.ts's identical early bail at the top of
      // `refreshDiff`'s own catch block.
      if (generation !== this.openGeneration || fetchToken !== this.externalChangeFetchToken) return;
      if (err instanceof SpacesBridgeError && err.code === "invalidArgument") {
        // Fix 3 (round-2): `invalidArgument` is the daemon's durable, decoded answer for a file that
        // can never be read as text — over the 10 MiB `workspaceFileRead` cap, or not valid UTF-8
        // (see `CodePaneBridge.swift`'s `fileReadPayload`/`mapClientError`), not a transient failure
        // like the generic branch below handles. Retrying it forever would silently poll a file that
        // can never succeed. This run reached a decoded outcome, so the retry counter resets exactly
        // like the `notFound`/success paths below, and the failure is surfaced — but WITHOUT
        // scheduling a retry, and WITHOUT tearing down the open-file state or the signature
        // subscription: recovery is left to the next signature-change event naturally re-entering
        // this method (e.g. the file shrinking back under the cap, or being rewritten as valid
        // UTF-8), not a retry loop of our own. A dirty buffer's own write stays CAS-guarded (see
        // `performSave()`), so nothing here risks silently overwriting unsaved local edits.
        this.externalChangeRetryFailures = 0;
        this.unreadableBannerVisible = true;
        this.banner.className = "banner error";
        this.banner.textContent = err.message;
        this.banner.style.display = "flex";
        return;
      }
      if (!(err instanceof SpacesBridgeError) || err.code !== "notFound") {
        // Not an authoritative "the file is gone" answer (offline device, daemon hiccup, a
        // transport failure) — this read could not run to a decodable conclusion at all, unlike
        // `notFound`, which IS a decoded, durable answer. The daemon only broadcasts a fresh
        // `spaces:fileSignature` frame when the signature VALUE changes, and the Swift host itself
        // dedupes repeat values across same-path resubscribes (see `subscribeToFileSignature`'s doc
        // comment) — so without a retry of our own, an external change that lands during exactly
        // this failure window would never be seen again until the file changes AGAIN on disk,
        // silently losing whatever an agent or another process just wrote. Retry with the same
        // bounded backoff root.ts's `scheduleDiffRetry` uses (mirrored here, not imported — see
        // `externalChangeRetryFailures`'s doc comment).
        this.scheduleExternalChangeRetry(fetchToken, generation);
        return;
      }
      disk = undefined;
    }
    // A decoded answer landed — either a successful read or `notFound`'s authoritative "the file is
    // gone" — so this run is done retrying. Reset here (not just on the next scheduled attempt) so a
    // later transient failure, from a fresh trigger, starts its own backoff at the floor instead of
    // inheriting whatever count this run left behind — mirrors root.ts's identical reset on a
    // durable outcome in `refreshDiff`.
    this.externalChangeRetryFailures = 0;
    if (generation !== this.openGeneration) return; // a later loadFile() already won
    if (fetchToken !== this.externalChangeFetchToken) return; // a later external-change fetch already won
    if (path !== this.currentPath) return;

    if (this.unreadableBannerVisible) {
      // This run reached a decoded outcome (a successful read, or `notFound` below), so whatever
      // made the file unreadable no longer holds. Clear the stale `invalidArgument` error now, before
      // branching on the read result below: every branch below either overwrites the banner with its
      // own (deleted placeholder, conflict, merge indicator) or leaves it hidden (same-hash return,
      // clean-buffer reload), so clearing first is harmless in all of them. Gated on the flag itself
      // (not run unconditionally) so this can never clear a banner this run did not put up — see the
      // flag's doc comment.
      this.unreadableBannerVisible = false;
      this.banner.style.display = "none";
    }

    if (disk === undefined) {
      if (!this.dirty) {
        this.showDeletedPlaceholder(path);
      } else if (this.confirmedBaseSHA256 === null) {
        // Still gone, and the user has already said to recreate it with this buffer. Re-entering the
        // conflict here would throw that decision away and ask for it again, once per reconcile, for
        // as long as the create write keeps failing. `baseSHA256` is still the create sentinel, so
        // the write the scheduler is already retrying carries the right target.
        this.scheduler.reevaluate();
      } else {
        this.enterConflictState({ content: "", sha256: undefined, missing: true });
      }
      return;
    }
    // The file exists again, so nothing about a deleted file is still true: whoever recreated it,
    // every branch below re-derives this pane's relationship to disk from the content just read.
    this.confirmedBaseSHA256 = undefined;

    if (disk.sha256 === this.baseSHA256) return; // spurious: disk already matches what this pane holds

    if (!this.dirty) {
      // Clean buffer: silently reload and adopt the new baseline. `loadIntoCodeView` reuses the
      // same item id, which is what gives this a best-effort scroll-preserving reload for free.
      this.baseSHA256 = disk.sha256;
      this.baseContent = disk.content;
      this.latestContent = disk.content;
      this.loadIntoCodeView(path, disk.content);
      // A live Undo offer names the exact buffer this reload just replaced, so it goes with it:
      // reverting to a pre-merge snapshot of content that is no longer on screen would discard the
      // disk-side change this reload just adopted.
      if (this.pendingMergeUndo !== undefined) {
        this.pendingMergeUndo = undefined;
        this.banner.style.display = "none";
      }
      this.pushEditorStateNow();
      return;
    }

    if (disk.content === this.latestContent) {
      // Buffer-level analog of the `disk.sha256 === this.baseSHA256` spurious guard above: that one
      // catches disk matching the BASELINE, this one catches disk matching the BUFFER. Disk already
      // holds exactly what's showing in the editor, so there is nothing to merge and nothing unsaved
      // — routing this into `diff3MergeLines` below would merge ours == theirs, which is a no-op on
      // content but still flips on the "Merged external changes." banner and (per the dirty branch's
      // own rule) leaves `dirty` true, so autosave would write again, for a merge that never
      // actually happened.
      //
      // Canonical trigger: this pane's OWN save. The CAS write lands on disk, the 2s file-signature
      // poll picks it up and pushes an external-change event, and this read completes before the
      // save's own network response returns. That push already bumped `externalChangeFetchToken`, so
      // the save's late success arm correctly stands down per its existing fetch-token guard (:1067)
      // — this branch is what records the clean outcome instead, since that guard only defers to
      // whatever `handleExternalChange` decides. An external writer that coincidentally writes exactly
      // the buffer's content reconciles identically through this same branch.
      //
      // The banner hide mirrors the save-success arm, and is what clears the conflict compare view
      // in the dissolve case below (where `pendingMergeUndo` is always undefined already, since
      // `enterConflictState` clears it). It is gated on the merge offer for the same reason the
      // save-success arm is: the canonical trigger here is this pane's own write of a merged buffer
      // landing, and retiring the offer on that would make Undo unreachable a poll interval after
      // every auto-merge.
      this.baseSHA256 = disk.sha256;
      this.baseContent = disk.content;
      this.dirty = false;
      if (this.pendingMergeUndo === undefined) this.banner.style.display = "none";
      if (this.conflict) {
        // Disk now holds exactly the frozen buffer `enterConflictState` adopted, so the disagreement
        // the conflict latched no longer exists. Canonical trigger: `resolveConflictKeepMine`'s own
        // CAS write lands, the 2s file-signature poll's push beats the write's own response, that push
        // bumps `externalChangeFetchToken` so Keep-mine's own success arm stands down per its
        // fetchToken guard — this branch is what records the outcome instead. The compare view (not
        // the edit view) is on screen while conflicted, so restore the edit view explicitly.
        this.conflict = false;
        this.diskMissing = false;
        this.loadIntoCodeView(path, this.latestContent ?? "");
      }
      // Nothing left to write, and any block this dissolved is gone: settle the chip (and drop a
      // pending retry) rather than leaving it reporting a save that no longer has to happen.
      this.scheduler.reevaluate();
      this.pushEditorStateNow();
      return;
    }

    if (this.pendingSaveSubmitted !== undefined && disk.content === this.pendingSaveSubmitted) {
      // Disk holds exactly what this pane's own in-flight save submitted — the write landed and the
      // signature poll beat the write response back, while the user kept typing during the flight
      // (`latestContent` has already moved past `submitted`, so the branch above this one didn't
      // fire). This mirrors the save success arm's own rules (see `performSave()`'s success arm): adopt the
      // write's content/hash as the new CAS baseline, but the buffer stays dirty because
      // `latestContent` moved past `submitted` during the flight — that extra content was never
      // written, and its next save CAS-checks correctly against this newly-adopted baseline.
      //
      // Routing this into `diff3MergeLines` below instead would merge ours-vs-theirs where both
      // diverged from the same old baseline on the same lines (the further typing landed on top of
      // what was just submitted), latching a false conflict for our own write — with no way to
      // correct it later, since the save's late arms stand down on their own fetch-token guard (see
      // `performSave()`'s `fetchToken` comment) once this reconcile has already run.
      //
      // The buffer stays dirty by construction here (we're inside the dirty path and
      // disk !== latestContent), so the scheduler writes the rest of it next. A CAS-rejected save
      // can also reach this branch with
      // `pendingSaveSubmitted` still set — the conflict arm awaits `handleExternalChange` before
      // `finally` runs — but it only fires if disk coincidentally equals the submitted content,
      // which is still the correct outcome to adopt in that case too.
      this.baseSHA256 = disk.sha256;
      this.baseContent = disk.content;
      // Unlike the two branches above, this one clears a live merge offer unconditionally: reaching
      // it means the buffer moved past what the write submitted, which only a keystroke does, and a
      // keystroke has already retired the offer. The clear is the belt-and-braces half of that.
      this.pendingMergeUndo = undefined;
      this.banner.style.display = "none";
      // The buffer moved past what the in-flight write submitted, so what is left still has to be
      // written, now against the baseline just adopted.
      this.scheduler.reevaluate();
      this.pushEditorStateNow();
      return;
    }

    if (this.conflict) {
      // A standing conflict must stay latched until the user explicitly resolves it (Keep mine / Take
      // disk). Routing a further disk-side write through the auto-merge below would diff3 against the
      // base `enterConflictState` adopted — the conflicting disk snapshot itself — so any follow-up
      // edit outside the disputed hunk would read as a clean merge whose disputed hunk is "ours",
      // silently resuming autosave and letting it overwrite the other writer's version with no
      // Keep-mine. Re-entering instead refreshes the compare view against the newest disk state and
      // keeps Keep-mine's CAS baseline current — the same treatment the first conflicting write got.
      // The buffer==disk branch above is the one way a conflict dissolves without explicit resolution,
      // because there the disagreement itself is gone (disk now equals the frozen buffer exactly).
      this.enterConflictState({ content: disk.content, sha256: disk.sha256, missing: false });
      return;
    }

    const merge = diff3MergeLines(this.latestContent ?? "", this.baseContent ?? "", disk.content);
    if ("conflict" in merge) {
      this.enterConflictState({ content: disk.content, sha256: disk.sha256, missing: false });
      return;
    }
    this.pendingMergeUndo = this.latestContent;
    this.baseSHA256 = disk.sha256;
    this.baseContent = disk.content;
    this.latestContent = merge.merged;
    this.loadIntoCodeView(path, merge.merged);
    this.showMergeIndicator(path);
    // The merged buffer is still dirty (the original edit is still there, now recombined with disk's
    // change) and nothing on disk holds it yet, so it has to be written again, against the baseline
    // this merge just adopted.
    this.scheduler.reevaluate();
    this.pushEditorStateNow();
  }

  /**
   * Schedules the next attempt for a `handleExternalChange` read that failed to run to a decodable
   * conclusion (see the catch branch above), on the same bounded backoff autosave.ts uses for a
   * failed write: `retryDelayMs`'s floor, doubling, and cap, shared rather than restated here.
   *
   * Guarded by `fetchToken`/`generation` at fire time (not just captured at schedule time), each
   * covering a different racer:
   *   - `fetchToken`: a fresh `spaces:fileSignature` push event firing its own `handleExternalChange`
   *     call, OR `performSave()`'s CAS-conflict arm doing the same; either one bumps
   *     `externalChangeFetchToken` the same way this retry's own re-invocation would, since both
   *     routes funnel through this same function.
   *   - `generation`: a newer `loadFile()` moving this pane on to a different file entirely, independent
   *     of whether anything about the external-change flow itself has fired again.
   * Either makes this fire a no-op instead of re-fetching for content nobody is looking at anymore.
   */
  private scheduleExternalChangeRetry(fetchToken: number, generation: number): void {
    this.externalChangeRetryFailures += 1;
    const delay = retryDelayMs(this.externalChangeRetryFailures);
    clearTimeout(this.externalChangeRetryTimer);
    this.externalChangeRetryTimer = setTimeout(() => {
      if (fetchToken !== this.externalChangeFetchToken || generation !== this.openGeneration) return; // superseded while this retry was pending
      void this.handleExternalChange();
    }, delay);
  }

  /** The dismissible "Merged external changes" indicator shown after a clean diff3 auto-merge.
   *  "Dismiss" just hides it (the merge already stands, nothing to undo any more). "Undo" puts the
   *  pre-merge buffer back. Both stay reachable across the autosave that follows the merge, which is
   *  the whole point of the offer surviving a successful write. */
  private showMergeIndicator(path: string): void {
    const text = document.createElement("span");
    text.textContent = "Merged external changes.";
    const undoBtn = document.createElement("button");
    undoBtn.type = "button";
    undoBtn.className = "btn";
    undoBtn.textContent = "Undo";
    undoBtn.addEventListener("click", () => this.undoMerge(path));
    const dismissBtn = document.createElement("button");
    dismissBtn.type = "button";
    dismissBtn.className = "btn";
    dismissBtn.textContent = "Dismiss";
    dismissBtn.addEventListener("click", () => {
      this.pendingMergeUndo = undefined;
      this.banner.style.display = "none";
    });
    this.banner.className = "banner merge";
    this.banner.replaceChildren(text, undoBtn, dismissBtn);
    this.banner.style.display = "flex";
  }

  /** Undo is an ordinary buffer edit: it puts the pre-merge content back and lets autosave write it
   *  against whatever baseline the pane holds now (the merge's disk snapshot, or the hash of the
   *  merged write if that already landed). Disk therefore ends up back at the user's own content,
   *  which is what "undo this merge" means once the merge is already on disk. */
  private undoMerge(path: string): void {
    if (this.pendingMergeUndo === undefined || path !== this.currentPath) return;
    const restored = this.pendingMergeUndo;
    this.pendingMergeUndo = undefined;
    this.latestContent = restored;
    this.dirty = true;
    this.banner.style.display = "none";
    this.loadIntoCodeView(path, restored);
    this.scheduler.noteEdit();
    this.pushEditorStateNow();
  }

  /**
   * Common entry point into conflict state from every trigger: an overlapping diff3 result, a
   * further disk-side write while a conflict stands, or a dirty buffer whose file was deleted on
   * disk. Freezes the buffer (`this.latestContent`) as "mine" and adopts `disk` as the new CAS baseline
   * (`baseSHA256`/`baseContent`) even though the buffer itself is left untouched — so "Keep mine"'s
   * write CAS-checks against the exact disk state shown in the compare view, and so a second
   * disk-side write while this conflict is still unresolved is detected the same way the first one
   * was (see `resolveConflictKeepMine`).
   */
  private enterConflictState(disk: { content: string; sha256: string | undefined; missing: boolean }): void {
    this.diskMissing = disk.missing;
    // Sentinel for "no real disk hash to CAS against" while missing: no write can run while the
    // conflict blocks the scheduler, and `performSave` reads this empty string back as the CAS
    // create convention once "Keep mine" clears the block (see `resolveConflictKeepMine`).
    this.baseSHA256 = disk.sha256 ?? "";
    this.baseContent = disk.content;
    this.conflict = true;
    this.pendingMergeUndo = undefined; // Undo only applies to a standing auto-merge, not a real conflict
    // Stops autosave dead: the disagreement is the user's to resolve, and every further write would
    // be refused until they do.
    this.scheduler.reevaluate();
    this.renderConflictCompareView();
    this.pushEditorStateNow();
  }

  /** Builds the read-only two-way compare (buffer vs. disk) shown while `this.conflict` is true,
   *  reusing the shared `CodeView` instance in its non-edit `"diff"` mode via `parseDiffFromFile`
   *  (which diffs two raw strings directly, unlike diffView.ts's `processFile`, which needs an
   *  existing unified-patch string). */
  private renderConflictCompareView(): void {
    const path = this.currentPath;
    if (!path) return;
    const mineFile: FileContents = {
      name: path,
      contents: this.latestContent ?? "",
      cacheKey: `${path}:mine`,
      lang: resolveAllowedLanguage(path),
    };
    const oldFile: FileContents | null = this.diskMissing
      ? null
      : { name: path, contents: this.baseContent ?? "", cacheKey: `${path}:disk`, lang: resolveAllowedLanguage(path) };
    const fileDiff = parseDiffFromFile(oldFile, mineFile, undefined, false);

    const codeView = this.ensureCodeView();
    this.editGeneration += 1;
    codeView.setItems([{ id: path, type: "diff", fileDiff, version: this.editGeneration }]);

    const text = document.createElement("span");
    text.textContent = this.diskMissing ? `${path} was deleted on disk.` : `${path} changed on disk.`;
    const keepMineBtn = document.createElement("button");
    keepMineBtn.type = "button";
    keepMineBtn.className = "btn primary";
    keepMineBtn.textContent = "Keep mine";
    const takeDiskBtn = document.createElement("button");
    takeDiskBtn.type = "button";
    takeDiskBtn.className = "btn";
    takeDiskBtn.textContent = this.diskMissing ? "Close without saving" : "Take disk";
    takeDiskBtn.addEventListener("click", () => this.resolveConflictTakeDisk());
    keepMineBtn.addEventListener("click", () => void this.resolveConflictKeepMine());

    this.banner.className = "banner conflict";
    this.banner.replaceChildren(text, keepMineBtn, takeDiskBtn);
    this.banner.style.display = "flex";
  }

  /** Conflict compare view's "Keep mine": the user's decision to overwrite disk with the frozen
   *  buffer. Clearing the conflict is the whole decision, and the ordinary autosave write is what
   *  carries it out, CAS-checked against the exact disk snapshot the compare view was showing (or
   *  the create convention when that snapshot is "deleted", to recreate the file: see
   *  `enterConflictState`'s empty-string sentinel and `performSave`'s reading of it).
   *
   *  The buffer is dirty by construction here, since every route into conflict state comes from a
   *  dirty buffer, so the flush always has something to write. Dismissing the compare view before
   *  the write settles is deliberate: it is what makes "Take disk" unreachable the moment this
   *  decision is taken, rather than leaving a stale second option on screen that a slow write could
   *  race. A write that CAS-conflicts again re-enters conflict against the newest disk state through
   *  `handleExternalChange`, which puts a fresh compare view (and both actions) back up. */
  private async resolveConflictKeepMine(): Promise<void> {
    const path = this.currentPath;
    if (!path) return;
    // Recorded before the flags are cleared, and pushed below with the rest of the state: the write
    // this releases can fail, and the file stays missing until one lands, so a reconcile or a
    // restart in between must find the decision already made rather than re-derive the conflict.
    if (this.diskMissing) this.confirmedBaseSHA256 = null;
    this.conflict = false;
    this.diskMissing = false;
    this.banner.style.display = "none";
    this.loadIntoCodeView(path, this.latestContent ?? "");
    this.pushEditorStateNow();
    await this.scheduler.flush();
  }

  /** Conflict compare view's "Take disk" ("Close without saving" when the file is missing):
   *  discards the buffer and adopts disk. For the deleted case there is no disk content to load, so
   *  this just becomes the same "no file open" placeholder state a clean buffer's deletion shows. */
  private resolveConflictTakeDisk(): void {
    const path = this.currentPath;
    if (!path) return;
    if (this.diskMissing) {
      this.showDeletedPlaceholder(path);
      return;
    }
    const content = this.baseContent ?? "";
    this.latestContent = content;
    this.dirty = false;
    this.conflict = false;
    this.confirmedBaseSHA256 = undefined; // the buffer is disk's now; there is nothing left to confirm
    this.banner.style.display = "none";
    this.loadIntoCodeView(path, content);
    // The block is gone and the buffer now matches disk: nothing left to write.
    this.scheduler.reevaluate();
    this.pushEditorStateNow();
  }

  /** Renders the "file deleted on disk" placeholder: used both when a clean buffer's file
   *  disappears (`handleExternalChange`'s not-dirty+missing branch) and when the conflict compare
   *  view's "Close without saving" is clicked on a missing file. Resets to a no-open-file state
   *  internally (there is nothing left to save or diff against) while leaving the path visible in
   *  the top bar's path label, per the locked UX ("path stays in box"). `collectEditorState` returns
   *  `undefined` for this state (same as never having opened a file) — an accepted simplification,
   *  since there is nothing meaningful left to survive a hibernation cycle here beyond the path
   *  itself, which isn't part of the persisted snapshot's contract.
   *
   *  The item keeps the same `id` a normal open uses for this path, not a distinct placeholder id:
   *  if the file is recreated on disk while this placeholder is showing, the still-live
   *  file-signature subscription (never torn down by this method) drives `handleExternalChange`
   *  right back through its normal not-dirty reload branch, and reusing the id gives that recovery
   *  the same scroll-preserving reuse a normal reload gets — an emergent, low-risk bonus rather than
   *  a separately-built recovery path. */
  private showDeletedPlaceholder(path: string): void {
    this.currentPath = path;
    this.baseSHA256 = undefined;
    this.baseContent = undefined;
    this.latestContent = undefined;
    this.dirty = false;
    this.conflict = false;
    this.diskMissing = false;
    this.confirmedBaseSHA256 = undefined;
    this.pendingMergeUndo = undefined;
    this.banner.style.display = "none";
    this.setPathLabel(path);
    // The file this session was saving is gone from disk, and there is no buffer or baseline left to
    // write against: the session is over, so the chip reports nothing rather than a "Saved" about a
    // file that no longer exists.
    this.scheduler.reset();

    const codeView = this.ensureCodeView();
    this.editGeneration += 1;
    codeView.setItems([
      {
        id: path,
        type: "file",
        file: { name: path, contents: "File deleted on disk.", lang: "text", cacheKey: `${path}:deleted` },
        version: this.editGeneration,
      },
    ]);
    this.pushEditorStateNow();
  }

  /**
   * Rehydrates the editor from the host's post-hibernation snapshot (`spaces:init`'s
   * `editorState` field, see README.md "Editor state survives hibernation"). Called once at
   * startup, before anything else touches this view.
   *
   * - `state` absent: nothing to restore — blank editor, same as a pane's first-ever load.
   * - `state.dirty`: the buffer had unsaved edits when the pane last hibernated. Restoring the
   *   exact buffer + CAS baseline the host held, with NO disk re-read, is what makes those edits
   *   survive — a re-read here would silently discard them in favor of whatever is on disk.
   *   `state.conflict` restores straight into conflict state (skipping edit mode entirely): the
   *   snapshot doesn't distinguish "changed" from "deleted on disk" on disk (`diskMissing` is
   *   deliberately not part of `CodePaneEditorState` — see its doc comment), so this always shows
   *   the more common "changed" wording until `handleExternalChange` (below) corrects it.
   * - not dirty: the buffer matched disk when it was pushed, so the snapshot's own content is
   *   restored directly, the same shape the dirty branches use, rather than re-read through
   *   `loadFile()` (round-16 Fix 1). `loadFile()`'s catch renders a bare error and returns on a read
   *   failure, leaving no path in the box and no subscription installed — strictly worse than the
   *   "File deleted on disk" placeholder a visible pane shows for the same deletion. Restoring the
   *   snapshot first and reconciling through `handleExternalChange` gives the clean case every
   *   outcome `loadFile()` had (disk unchanged is a same-hash no-op, disk changed silently reloads) plus
   *   the ones it didn't (disk deleted shows the placeholder instead of an error; a transport-shaped
   *   read failure gets `handleExternalChange`'s own bounded-backoff retry instead of giving up) —
   *   at no extra read cost, since `handleExternalChange` always does its own fresh read regardless
   *   of caller.
   *
   * None of the three branches replaces the restored buffer from disk before firing
   * `handleExternalChange`, but every one of them fires it once the restored state is in place:
   * its own `workspaceFileRead` is the host's ONLY trigger for re-arming the daemon's
   * file-signature stream (`subscribeToFileSignature` here is just a DOM listener; teardown clears
   * the host's subscription state and nothing else re-establishes it), and its existing 4-case
   * decision reconciles whatever happened on disk during hibernation — a no-op when disk still
   * matches `baseSHA256`, silent-reload/diff3/conflict when it changed, or the deleted branches
   * when the file is gone — without ever clobbering the restored buffer, by the same rules it
   * already applies to a live external-change event.
   *
   * Never fires `onFileOpened`: every branch below restores the buffer via `loadIntoCodeView`
   * directly, not `loadFile()` — re-opening a hibernated pane's last file isn't a user-initiated
   * open, so it must not re-record that path as a new recent.
   */
  async restoreState(state: CodePaneEditorState | undefined): Promise<void> {
    if (!state) return;
    if (!state.dirty) {
      this.setPathLabel(state.path);
      this.currentPath = state.path;
      this.baseSHA256 = state.baseSHA256;
      this.baseContent = state.baseContent;
      this.latestContent = state.content;
      this.dirty = false;
      this.conflict = false;
      this.diskMissing = false;
      this.confirmedBaseSHA256 = undefined;
      this.pendingMergeUndo = undefined;
      this.banner.style.display = "none";
      this.loadIntoCodeView(state.path, state.content);
      this.subscribeToFileSignature(state.path);
      // No push here: this is a same-value echo of the snapshot the host already holds, not a new
      // state transition — pushing it back would be a no-op round trip (same reasoning as the
      // non-conflict dirty branch below).
      // Reconciles against whatever happened on disk during hibernation and re-arms the host's
      // file-signature stream (see this method's doc comment) — fired after the restored state is
      // already in place so the reconcile operates on the snapshot's own baseline.
      void this.handleExternalChange();
      return;
    }
    this.setPathLabel(state.path);
    this.currentPath = state.path;
    this.baseSHA256 = state.baseSHA256;
    this.baseContent = state.baseContent;
    this.latestContent = state.content;
    this.dirty = true;
    // A confirmed Keep mine outstanding when the pane went away: the reconcile fired below must not
    // ask for that decision again (see the field's doc comment).
    this.confirmedBaseSHA256 = state.confirmedBaseSHA256;
    this.pendingMergeUndo = undefined;
    this.subscribeToFileSignature(state.path);
    if (state.conflict) {
      this.diskMissing = false;
      this.conflict = true;
      // A restored conflict is still a block: the chip must say so without waiting for an edit.
      this.scheduler.reevaluate();
      this.renderConflictCompareView();
      // Reconciles against whatever happened on disk during hibernation and re-arms the host's
      // file-signature stream (see this method's doc comment) — fired after the compare view is
      // already in place so the reconcile operates on the restored state.
      void this.handleExternalChange();
      return;
    }
    this.conflict = false;
    this.diskMissing = false;
    this.banner.style.display = "none";
    // The restored buffer holds edits disk has never seen, so it autosaves on the same debounce a
    // live keystroke would arm: hibernating a pane must not be a way to leave an edit unwritten.
    this.scheduler.noteEdit();
    this.loadIntoCodeView(state.path, state.content);
    // No push here: this is a same-value echo of the snapshot the host already holds, not a new
    // state transition — pushing it back would be a no-op round trip.
    // Reconciles against whatever happened on disk during hibernation and re-arms the host's
    // file-signature stream (see this method's doc comment) — fired after the buffer/state fields
    // above are already in place so the reconcile operates on the restored state.
    void this.handleExternalChange();
  }

  /** Builds the editor's current open-file snapshot, or `undefined` when no file is open. Shared by
   *  `pushEditorStateNow` (the push path) and `collectStateForFlush` (the host's teardown pull), so
   *  the two can't disagree about what "current state" means. */
  private collectEditorState(): CodePaneEditorState | undefined {
    if (
      !this.currentPath ||
      this.baseSHA256 === undefined ||
      this.baseContent === undefined ||
      this.latestContent === undefined
    ) {
      return undefined;
    }
    return {
      path: this.currentPath,
      baseSHA256: this.baseSHA256,
      baseContent: this.baseContent,
      content: this.latestContent,
      dirty: this.dirty,
      conflict: this.conflict,
      // Present only while a decision is outstanding: absent and `null` mean different things to the
      // restore below, so the key is omitted rather than written as undefined.
      ...(this.confirmedBaseSHA256 !== undefined ? { confirmedBaseSHA256: this.confirmedBaseSHA256 } : {}),
    };
  }

  /** Sends the editor's current open-file snapshot (or `undefined` when no file is open) to the
   *  host immediately, bypassing the debounce timer. Called on every discrete transition (open,
   *  save, external-change) rather than just left to the debounced path, so those transitions can't
   *  be lost to a hibernation racing the trailing timer. The payload is at most the file's content
   *  twice over (`content` + `baseContent`, already capped at the existing 10 MiB
   *  `workspaceFileRead` limit; real sources are typically KBs) — the extra postMessage/
   *  structured-clone cost on every edit is accepted as cheap relative to losing the user's buffer
   *  or its diff3 merge base. */
  private pushEditorStateNow(): void {
    // The host has torn its own state down; re-arming its persistence from a settling write's
    // continuation would resurrect a document for a pane that is gone.
    if (this.disposed) return;
    clearTimeout(this.editorStatePushTimer);
    this.callbacks.onStateChanged?.(this.collectEditorState());
    this.callbacks.onStateTransition?.();
  }

  /** Trailing debounce for the push on buffer edits: a keystroke-by-keystroke push would be wasted
   *  work between keystrokes, while the immediate pushes above already cover every transition that
   *  can't tolerate the delay. A buffer edit inside this window used to be at risk of loss if a
   *  hibernating teardown landed before the timer fired; that race is closed by the unified
   *  `window.__spacesCollectWorkspaceState` collector, which the Swift host pulls synchronously. */
  private scheduleEditorStatePush(): void {
    clearTimeout(this.editorStatePushTimer);
    this.editorStatePushTimer = setTimeout(() => this.pushEditorStateNow(), EDITOR_STATE_DEBOUNCE_MS);
  }

  /** Current open-file source state for the host-pulled unified workspace collector. */
  collectStateForFlush(): string | null {
    const state = this.collectEditorState();
    return state ? JSON.stringify(state) : null;
  }

  /** Current source-state snapshot for the pane-level persistence document. */
  snapshot(): CodePaneEditorState | undefined {
    return this.collectEditorState();
  }

  /**
   * The scheduler's `performSave`: one CAS write of the live buffer, reporting what happened rather
   * than painting it (the chip is `renderSaveStatus`'s job). The scheduler never starts this while a
   * previous call is in flight, and never at all while `blockedReason()` says the user has something
   * to resolve first.
   *
   * `clean` covers every "there is nothing to write" case, including the late arms that stand down
   * because a newer open or a newer external-change reconcile already owns this pane's state; a
   * `conflict` result routes into the same `handleExternalChange` ladder a live signature push uses
   * and reports whatever that ladder decided (a merged buffer is still dirty, so the scheduler writes
   * again immediately; a real conflict is a block); and a rejected write is `failed`, which the
   * scheduler retries on its own backoff.
   */
  private async performSave(): Promise<SaveOutcome> {
    // `baseSHA256 === ""` is `enterConflictState`'s "disk holds no file" sentinel, which is the CAS
    // create convention below, so it is a writable baseline here rather than a missing one.
    if (!this.currentPath || this.latestContent === undefined || this.baseSHA256 === undefined) return "clean";
    if (!this.dirty) return "clean";
    if (this.saveInFlight) return "clean";
    this.saveInFlight = true;
    // Captured before the await, alongside `submitted` below: identifies which file this save
    // belongs to. If the user opens a different file before this write resolves, `openGeneration`
    // moves on and this call's completion must not touch `baseSHA256`/`dirty`/`conflict`/the banner:
    // all of those now describe the newly opened file, not this one.
    const generation = this.openGeneration;
    // Fix 2 (round-2): `generation` alone only guards against a NEWER loadFile() — it says nothing about
    // a `handleExternalChange` reconcile completing for the SAME file while this write is still in
    // flight (e.g. a live `spaces:fileSignature` push for this pane's own write landing on disk,
    // racing this call's own success/failure response). That reconcile can set `pendingMergeUndo`,
    // the merge indicator, or full conflict state — this save's late-arriving arms below must not
    // clobber whatever it decided. Captured here, alongside `generation`, and re-checked after the
    // write settles (see both arms below).
    const fetchToken = this.externalChangeFetchToken;
    try {
      // Captured before the await: this exact string is what's being submitted, and (per the
      // success arm below) what ends up on disk. `this.latestContent` can move on underneath this
      // call if the user keeps typing while the write is in flight — the two must not be conflated.
      const submitted = this.latestContent;
      // Fix 1: identifies this in-flight write's exact content for `handleExternalChange` to
      // recognize (see `pendingSaveSubmitted`'s doc comment). Cleared in this method's `finally`.
      this.pendingSaveSubmitted = submitted;
      let result: WorkspaceFileWriteResult;
      try {
        result = await this.bridge.workspaceFileWrite(this.currentPath, submitted, {
          baseSHA256: this.baseSHA256 === "" ? undefined : this.baseSHA256,
          purpose: "editor",
        });
      } catch (err) {
        if (generation !== this.openGeneration) return "clean"; // a later loadFile() already won; this failure is moot
        // Fix 2 (round-2): a `handleExternalChange` reconcile for this same file completed while this
        // write was in flight and already decided this file's UI state (merge indicator, conflict
        // compare, or a silent clean reload) — this failure is for a write that's now superseded by
        // that decision, so reporting it would back off a write the reconcile has already reshaped.
        // See `fetchToken`'s doc comment above.
        if (fetchToken !== this.externalChangeFetchToken) return "clean";
        // A rejected write (offline device, timeout, daemon error — e.g. a `SpacesBridgeError` with
        // code `unavailable`) never got a decodable answer from the daemon at all, unlike the
        // `conflict` branch below which is a durable CAS rejection the daemon *did* decode and
        // apply its rules to. Treat it as transient: report it factually, with the buffer left
        // dirty, so the scheduler retries the same write rather than latching the way a real
        // conflict does.
        const message = err instanceof SpacesBridgeError ? err.message : "Failed to save file.";
        // No state push: a write that never landed leaves the snapshot (path, baseline, buffer,
        // dirty, conflict) exactly as it was, and a backoff that keeps failing would otherwise push
        // that same unchanged document over and over.
        return { failed: message };
      }
      if (generation !== this.openGeneration) {
        // A newer loadFile() already moved this pane on to a different file. The write above was still
        // a valid CAS write for the superseded file's own content against its own baseline, so
        // disk is correct either way; there is just no in-memory editor state left for it to update.
        return "clean";
      }
      if ("conflict" in result) {
        // Captured so the arm below can tell a reconcile that actually moved this pane's CAS
        // baseline from one that could not.
        const refusedBaseline = this.baseSHA256;
        // Deliberately NOT guarded by `fetchToken` (Fix 2, round-2): this only re-invokes
        // `handleExternalChange()`, which is idempotent against whatever an already-in-flight
        // reconcile did — it always does its own fresh read and re-derives state from scratch, so
        // calling it again here (superseded or not) is harmless. Route into the same external-change
        // handling a live file-signature push uses: a CAS rejection is itself evidence disk moved
        // since this save's baseline, and `handleExternalChange` always does its own fresh read
        // rather than trusting this result's (possibly already-stale-again)
        // `currentSHA256`/`fileMissing`, see its doc comment. That ladder either merges (leaving a
        // dirty buffer the scheduler writes again straight away, against the baseline it adopted) or
        // enters conflict, which is the block reported here.
        await this.handleExternalChange();
        if (this.blockedReason() !== undefined) return "blocked";
        // The ladder reached no new baseline: its own read could not run to a decodable answer (it
        // has scheduled its own retry) or disk went back to the very hash this write was just
        // refused against. Writing the same content against the same baseline again, which is what
        // reporting "clean" on a still-dirty buffer would do immediately, could only be refused the
        // same way, so this is reported as a failure and waits out the scheduler's backoff instead.
        if (this.dirty && this.baseSHA256 === refusedBaseline) {
          return { failed: "The file changed on disk and could not be re-read." };
        }
        return "clean";
      }
      // Fix 2 (round-2): a `handleExternalChange` reconcile for this same file completed while this
      // write was in flight and already decided this file's UI state — this plain-success path must
      // not overwrite it with a now-stale baseline/dirty/banner. See `fetchToken`'s doc comment
      // above. The write itself did land on disk, so it is still reported as saved: the reconcile
      // owns the pane's state, not the question of whether anything was written.
      if (fetchToken !== this.externalChangeFetchToken) return "saved";
      // The pair (submitted, write hash) is self-consistent by construction — adopt the write's own
      // hash as the next CAS baseline directly rather than re-reading the file. A re-read here would
      // instead race whatever else might write the file (e.g. an agent) between this save and the
      // read: a write landing in that window would make the re-read return someone else's hash
      // paired with this buffer's un-saved-again content, and the next save would then pass CAS and
      // silently overwrite it.
      this.baseSHA256 = result.sha256;
      this.baseContent = submitted;
      // The write landed, so the file exists with a real baseline and the create decision is spent.
      this.confirmedBaseSHA256 = undefined;
      // NOT unconditionally clean: the buffer showing in the editor right now is only guaranteed to
      // match disk if nothing was typed during the await. A keystroke that landed while this save was
      // in flight left `latestContent` ahead of `submitted` — that content was never written, so the
      // buffer must stay dirty against the baseline just adopted above (the scheduler writes it again
      // immediately, CAS-checked against this save's hash, which is correct: it is the disk state
      // that content hasn't seen yet).
      this.dirty = this.latestContent !== submitted;
      // Clears a banner left over from before this successful save (a refused open's notice), but
      // NOT a live merge indicator: the write that just landed is usually the merged buffer's own
      // autosave, and the Undo offer is precisely the offer to take that back, so a successful write
      // never retires it. It is retired by a keystroke, an external change that replaces the buffer,
      // a conflict, or opening another file.
      if (this.pendingMergeUndo === undefined) this.banner.style.display = "none";
      // Immediate: a successful save is a discrete transition (new baseline, dirty possibly changed).
      this.pushEditorStateNow();
      return "saved";
    } finally {
      this.saveInFlight = false;
      this.pendingSaveSubmitted = undefined;
    }
  }
}
