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
import { afterBrowserPaint } from "./renderMetrics";

/** Trailing debounce for recovery-state pushes on buffer edits (see `scheduleEditorStatePush`). */
const EDITOR_STATE_DEBOUNCE_MS = 500;
/** A broken editor attach must not leave a frame callback alive for the pane's lifetime. */
const RESTORED_FOCUS_ATTACH_MAX_FRAMES = 120;
/** Bounded-backoff floor/cap for `handleExternalChange`'s execution-failure retry (see
 *  `scheduleExternalChangeRetry`'s doc comment) — identical values to root.ts's
 *  `DIFF_RETRY_FLOOR_MS`/`DIFF_RETRY_CAP_MS`, mirrored here rather than imported: root.ts keeps
 *  that retry state as private closures inside `mountRoot` with no exported reusable helper. */
const EXTERNAL_CHANGE_RETRY_FLOOR_MS = 1000;
const EXTERNAL_CHANGE_RETRY_CAP_MS = 30000;

export interface EditorViewCallbacks {
  /** Fired exactly when `loadFile()` completes a load that actually replaces the buffer with
   *  `path`'s content — the one seam every real open funnels through, whether it arrived via a
   *  direct `open()` call or via the discard-consent banner's own `loadFile(path, {
   *  discardConsentEditGeneration })` re-invocation. Deliberately NOT fired for: a refused open
   *  (`open()`'s dirty-buffer gate, which returns before ever calling `loadFile()`), a failed read
   *  (the catch branch), a re-raised discard banner (a stale consent), or a superseded load (an
   *  `openGeneration` bump already won) — see `loadFile`'s own branches for each. root.ts uses this
   *  to record `path` into recents and move the Files-tree selection (see its `openInEditor`),
   *  which is what keeps a refused or failed open from polluting either. */
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

/**
 * Editor mode: a single-file `@pierre/diffs` `CodeView` in edit mode, saved through the CAS
 * `workspaceFileWrite` call. This class owns no file-picking UI of its own — every file this view
 * shows arrives via its public `open()`, called by root.ts from the ⌘P quick-open overlay, Editor
 * mode's Files tree, or the Changes list (see quickOpen.ts/editorSidebar.ts/README.md's "Editor
 * mode" section for the three entry points and how root.ts routes between them). The top bar this
 * view renders is just the open file's path (or a "⌘P to open a file" hint when none is open) and
 * the Save button.
 *
 * External-change handling (disk changing under an open file) is a single shared path,
 * `handleExternalChange`, driven by two triggers — a `spaces:fileSignature` push event and a
 * `save()` CAS rejection — implementing four cases:
 *   - clean buffer + disk changed: silently reload, adopt the new baseline.
 *   - clean buffer + file deleted: swap in a "deleted on disk" placeholder.
 *   - dirty buffer + disk changed, non-overlapping edits: auto-merge via `diff3MergeLines`, with a
 *     dismissible "Merged external changes" indicator offering Undo.
 *   - dirty buffer + disk changed, overlapping edits (or Undo of an auto-merge) + dirty buffer with
 *     the file deleted: conflict state — Save blocked, a read-only compare view (buffer vs. disk)
 *     with "Keep mine" / "Take disk" (or "Close without saving" when deleted) actions.
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
  private readonly saveBtn: HTMLButtonElement;
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
  /** The buffer's content immediately before a diff3 auto-merge was applied, kept only long enough
   *  to offer "Undo" on the merge indicator. Cleared (and the indicator hidden) the moment any of:
   *  another edit lands on top of the merge (undo would silently discard it), the file is saved, a
   *  new file is opened, or a real conflict is entered. Deliberately NOT part of
   *  `CodePaneEditorState` (see its doc comment) — a hibernation cycle simply drops the Undo offer,
   *  which is an accepted, cheap-to-lose affordance rather than a data-loss risk. */
  private pendingMergeUndo: string | undefined;
  /** Monotonic count of buffer edits, bumped once per `onItemEditChange` firing. Used only to
   *  detect whether an edit landed between a discard consent (the "Discard edits and open" button
   *  click) and that discard's `loadFile()` call completing — see `showDiscardBanner`'s click
   *  handler and `loadFile()`'s completion check. Not persisted, not part of `CodePaneEditorState`:
   *  it only ever needs to compare two values captured within the same live session. */
  private bufferEditGeneration = 0;
  private editGeneration = 0;
  /** Bumped at the start of every `loadFile()` call; a call whose token has been superseded by a
   *  later `loadFile()` drops its result (success or failure) instead of clobbering whatever that
   *  later call already loaded. Same latest-wins shape as `root.ts`'s `diffRequestToken`. */
  private openGeneration = 0;
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
   *  comment), so a fresh trigger — a live signature event or `save()`'s CAS-conflict arm —
   *  supersedes whatever retry was pending without needing a separate reset path. */
  private externalChangeRetryFailures = 0;
  private externalChangeRetryTimer: ReturnType<typeof setTimeout> | undefined;
  /** True for the duration of one `save()` call. `saveBtn.disabled` alone doesn't stop re-entrancy:
   *  a second click already queued (or a programmatic `save()`) can still run before the first
   *  await yields control back to the DOM, and two overlapping CAS writes racing the same baseline
   *  would let the second silently win with a hash the first's in-flight write invalidates. */
  private saveInFlight = false;
  /** The exact content an in-flight `save()` submitted, set just before the write await and cleared
   *  in `save()`'s `finally`. Exists ONLY so `handleExternalChange` can recognize disk content that
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

    this.saveBtn = document.createElement("button");
    this.saveBtn.type = "button";
    this.saveBtn.className = "btn primary";
    this.saveBtn.textContent = "Save";
    this.saveBtn.disabled = true;
    this.saveBtn.addEventListener("click", () => void this.save());

    openBar.appendChild(this.saveBtn);

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
          this.bufferEditGeneration += 1;
          this.focusedLine = this.readFocusedLine() ?? this.focusedLine;
          this.saveBtn.disabled = this.conflict;
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
   * Public entry point for every way a file can be opened in Editor mode — the ⌘P quick-open
   * overlay, the Files tree, and the Changes list (see this class's doc comment) all call this and
   * nothing else. `loadFile()` itself stays ungated, since `restoreState`'s clean branch calls it
   * directly with nothing at risk (that path only ever follows a fresh restore, never an
   * in-progress edit).
   *
   * Silently replacing the buffer here would violate the spec's unsaved-edit
   * promise (README.md: "only quitting and reopening the app loses an unsaved edit") — a save-in-
   * progress buffer must not vanish just because a different file was opened. A modal confirmation
   * is out per this codebase's design rules (no new modal surfaces), so the existing non-blocking
   * banner carries the explicit discard consent instead: clicking its action is the one deliberate
   * way to abandon the current edit, distinct from the silent replace this gate refuses to do on
   * its own.
   *
   * This upfront check is a fast path only, not the whole contract. It
   * runs before the read starts, so it cannot see dirty state that arises WHILE that read is in
   * flight (the user typing into the currently-open file during a slow remote read) —
   * `loadFile()` itself re-checks dirty at completion and raises the identical banner if the race
   * occurred (see the completion-check comment inside `loadFile()`). And the banner's discard
   * button no longer clears `dirty` at click time: it commits the discard only once `loadFile()`
   * actually succeeds, via `loadFile(path, { discardConsentEditGeneration })`, so a read that fails
   * after a discard click leaves the old buffer correctly marked dirty rather than lying about it
   * having been abandoned. The generation carried by that option additionally scopes the consent to
   * the buffer as it stood at the click, not whatever the buffer becomes while the read is still in
   * flight — see `loadFile()`'s completion check.
   *
   * A standing conflict is dirty by construction (`this.dirty` stays true throughout), so it falls
   * through the same gate as any other unsaved buffer — opening a different file is one of the
   * ways to leave a conflict, alongside the compare view's own "Keep mine"/"Take disk" actions.
   */
  /** `options.revealLine`, when given, scrolls to and focuses that line once `path` is actually
   *  showing, the diff pane's "open at the clicked line" entry point. The line is a coordinate in
   *  the file as the diff saw it on disk, so the same-path short-circuit below ignores it: that
   *  branch only runs for a DIRTY buffer, whose unsaved insertions and deletions have already moved
   *  the disk's lines, and the file stays where the user left it. Every other branch hands the
   *  line to the `loadFile()` call that loads `path`, which applies it in its success path. The
   *  line travels WITH that load rather than through a shared field on purpose: the discard-consent
   *  gate's own `loadFile()` only happens later, on the banner click, and a second `open()` that
   *  hits the dirty gate while that consented load is still reading must not redirect the first
   *  file's reveal to the second open's line. */
  open(path: string, options?: { revealLine?: number }): void {
    // Re-picking the file already open (its own row in Files/Changes, or ⌘P again) must not fall
    // into the discard gate below: the file is already on screen, so there is nothing to open that
    // isn't already showing, and accepting the banner would reread disk and destroy the very edits
    // it claims to be protecting. A standing conflict is dirty by construction and never clears
    // `currentPath` (see this method's doc comment), so re-picking the same path mid-conflict also
    // lands here and just stays put, same as any other dirty same-path reopen.
    if (path === this.currentPath && this.dirty) return;
    if (this.dirty && this.currentPath !== undefined) {
      this.showDiscardBanner(path, options?.revealLine);
      return;
    }
    void this.loadFile(path, { revealLine: options?.revealLine });
  }

  /** Renders the non-blocking discard-consent banner used by `open`'s gate and by `loadFile()`'s
   *  own completion-time recheck (see both call sites' comments). Only ever called when
   *  `this.currentPath !== undefined` already holds, so reading it directly here is safe. */
  private showDiscardBanner(targetPath: string, revealLine?: number): void {
    const from = this.currentPath;
    const text = document.createElement("span");
    text.textContent = `Unsaved changes in ${from}. Save them first, or discard them to open ${targetPath}.`;
    const discardBtn = document.createElement("button");
    discardBtn.type = "button";
    discardBtn.className = "btn";
    discardBtn.textContent = "Discard edits and open";
    discardBtn.addEventListener("click", () => {
      // Captured here, inside the listener, not hoisted out to banner-render time: the consent this
      // click gives only covers the buffer AS IT STANDS RIGHT NOW. Reading `bufferEditGeneration` at
      // click time (rather than whatever value it happened to have when the banner was first shown)
      // is what lets `loadFile()`'s completion check detect an edit that lands during this call's own
      // read — see that check's comment.
      void this.loadFile(targetPath, { discardConsentEditGeneration: this.bufferEditGeneration, revealLine });
    });
    this.banner.className = "banner conflict";
    this.banner.replaceChildren(text, discardBtn);
    this.banner.style.display = "flex";
  }

  /** `opts.revealLine` is the line `open()` was asked to reveal in `path`; it belongs to this
   *  load alone and is applied only if this load is the one that ends up showing `path`. */
  private async loadFile(
    path: string,
    opts?: { discardConsentEditGeneration?: number; revealLine?: number },
  ): Promise<void> {
    const renderStartedAt = performance.now();
    const generation = ++this.openGeneration;
    let result: WorkspaceFileReadResult;
    try {
      result = await this.bridge.workspaceFileRead(path, "editor");
    } catch (err) {
      if (generation !== this.openGeneration) return; // a later loadFile() already won
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
    if (generation !== this.openGeneration) return; // a later loadFile() already won
    const isStaleConsent =
      opts?.discardConsentEditGeneration === undefined || opts.discardConsentEditGeneration !== this.bufferEditGeneration;
    if (isStaleConsent && this.dirty && this.currentPath !== undefined) {
      // Bug A fix (round-15): a DIFFERENT open (`open`'s own upfront check, which ran before
      // this read started) cannot see dirty state that arises WHILE this read is in flight — the
      // user may type into the currently-open file during the seconds a remote read can take.
      // Rechecking here, at completion, is what actually closes that race, showing the identical
      // consent banner instead of silently replacing the buffer.
      //
      // A discard consent only ever covers the buffer AS OF THE CLICK, not whatever the buffer
      // becomes while this call's own read is still in flight (a later fix, tracked via
      // `bufferEditGeneration`). Without the generation check, a discard-open's completion would
      // see `this.dirty === true` (never cleared before the call — that's Bug B's fix, deferring
      // the clear to this function's own success path below) and treat its OWN replacement as a
      // conflict, re-raising the very banner the user just dismissed — but ONLY re-raising it when
      // an edit actually landed after the click is what makes that re-raise correct rather than a
      // repeat of Bug B: a second click with `discardConsentEditGeneration` still matching the
      // current `bufferEditGeneration` (no edit landed in between) is exactly the "resolution
      // already given, do not re-litigate it" case Bug B's fix protects, and `isStaleConsent` is
      // false for it, so the buffer is replaced below and this cannot loop forever — each re-raise
      // requires the user to have typed something new, which is new unsaved work the original
      // consent never covered.
      this.showDiscardBanner(path, opts?.revealLine);
      // Same reconcile as the catch block above, for the same reason: this refusal leaves the
      // previously-open file (`this.currentPath`, guaranteed defined by this branch's own condition, so
      // no guard needed here unlike the catch block) current, and any of its own in-flight reconcile was
      // just discarded by the generation bump. This also repairs a Swift-side wrinkle: the successful
      // read for `path` already retargeted the device's file-signature subscription to `path`, so this
      // reconcile's own `workspaceFileRead(this.currentPath)` reaches Swift as a path change and its
      // success arm resubscribes the signature stream back to `this.currentPath` as a byproduct.
      void this.handleExternalChange();
      return;
    }
    this.setPathLabel(path);
    this.currentPath = path;
    this.baseSHA256 = result.sha256;
    this.baseContent = result.content;
    this.latestContent = result.content;
    this.dirty = false;
    this.conflict = false;
    this.diskMissing = false;
    this.pendingMergeUndo = undefined;
    this.banner.style.display = "none";
    // Fix 3 (round-24, P2): the flag scopes an unreadable-file error banner to the file that raised
    // it (see the flag's own doc comment). A successful open establishes a fresh file context, so it
    // must not leak into the next file's first decoded `handleExternalChange` reconcile, whose
    // unconditional-on-this-flag clear (around line 582) would otherwise hide an unrelated banner
    // (discard consent, merge indicator) that file put up, using state left over from a DIFFERENT
    // file.
    this.unreadableBannerVisible = false;
    this.saveBtn.disabled = true;
    // A successful open establishes a fresh file context: any execution-failure retry still
    // pending for the PREVIOUS file is already neutralized by the `openGeneration` bump above (its
    // fire-time check no-ops), but clearing it here too avoids a dangling timer and lets this new
    // file's own retry backoff (if it ever needs one) start at the floor.
    clearTimeout(this.externalChangeRetryTimer);
    this.externalChangeRetryFailures = 0;

    this.loadIntoCodeView(path, result.content);
    if (opts?.revealLine !== undefined) this.restorePosition(opts.revealLine, opts.revealLine);
    afterBrowserPaint(() => {
      if (generation !== this.openGeneration || this.currentPath !== path) return;
      this.callbacks.onFileRendered?.(path, Math.max(performance.now() - renderStartedAt, 0), result.content.length);
    });
    this.subscribeToFileSignature(path);
    // Immediate, not debounced: a file open is a discrete transition, not a buffer edit.
    this.pushEditorStateNow();
    // The one place a load actually completes (see `EditorViewCallbacks.onFileOpened`'s doc
    // comment) — every earlier return in this method (the catch branch, the stale-consent
    // re-raise, the generation checks) skips this line, which is what keeps a refused or failed
    // open from firing it.
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
   * file-signature listener above (a push event) and by `save()`'s CAS-conflict arm (a rejected
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
        // UTF-8), not a retry loop of our own. A dirty buffer's own Save stays CAS-guarded (see
        // `save()`), so nothing here risks silently overwriting unsaved local edits.
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
      } else {
        this.enterConflictState({ content: "", sha256: undefined, missing: true });
      }
      return;
    }

    if (disk.sha256 === this.baseSHA256) return; // spurious: disk already matches what this pane holds

    if (!this.dirty) {
      // Clean buffer: silently reload and adopt the new baseline. `loadIntoCodeView` reuses the
      // same item id, which is what gives this a best-effort scroll-preserving reload for free.
      this.baseSHA256 = disk.sha256;
      this.baseContent = disk.content;
      this.latestContent = disk.content;
      this.loadIntoCodeView(path, disk.content);
      // Explicit, not left over from whatever triggered this: a save() CAS conflict disables Save
      // before routing here, and a clean buffer must leave it disabled (nothing unsaved exists).
      this.saveBtn.disabled = true;
      this.pushEditorStateNow();
      return;
    }

    if (disk.content === this.latestContent) {
      // Buffer-level analog of the `disk.sha256 === this.baseSHA256` spurious guard above: that one
      // catches disk matching the BASELINE, this one catches disk matching the BUFFER. Disk already
      // holds exactly what's showing in the editor, so there is nothing to merge and nothing unsaved
      // — routing this into `diff3MergeLines` below would merge ours == theirs, which is a no-op on
      // content but still flips on the "Merged external changes." banner and (per the dirty branch's
      // own rule) leaves `dirty` true with Save enabled for a merge that never actually happened.
      //
      // Canonical trigger: this pane's OWN save. The CAS write lands on disk, the 2s file-signature
      // poll picks it up and pushes an external-change event, and this read completes before the
      // save's own network response returns. That push already bumped `externalChangeFetchToken`, so
      // the save's late success arm correctly stands down per its existing fetch-token guard (:1067)
      // — this branch is what records the clean outcome instead, since that guard only defers to
      // whatever `handleExternalChange` decides. An external writer that coincidentally writes exactly
      // the buffer's content reconciles identically through this same branch.
      //
      // Banner-hide and `pendingMergeUndo` clear mirror the save-success arm (:1085-1086): buffer ==
      // disk == baseline leaves nothing to undo and nothing to report.
      this.baseSHA256 = disk.sha256;
      this.baseContent = disk.content;
      this.dirty = false;
      this.saveBtn.disabled = true;
      this.pendingMergeUndo = undefined;
      this.banner.style.display = "none";
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
      this.pushEditorStateNow();
      return;
    }

    if (this.pendingSaveSubmitted !== undefined && disk.content === this.pendingSaveSubmitted) {
      // Disk holds exactly what this pane's own in-flight save submitted — the write landed and the
      // signature poll beat the write response back, while the user kept typing during the flight
      // (`latestContent` has already moved past `submitted`, so the branch above this one didn't
      // fire). This mirrors the save success arm's own rules (see `save()`'s success arm): adopt the
      // write's content/hash as the new CAS baseline, but the buffer stays dirty because
      // `latestContent` moved past `submitted` during the flight — that extra content was never
      // written, and its next save CAS-checks correctly against this newly-adopted baseline.
      //
      // Routing this into `diff3MergeLines` below instead would merge ours-vs-theirs where both
      // diverged from the same old baseline on the same lines (the further typing landed on top of
      // what was just submitted), latching a false conflict for our own write — with no way to
      // correct it later, since the save's late arms stand down on their own fetch-token guard (see
      // `save()`'s `fetchToken` comment) once this reconcile has already run.
      //
      // Save stays enabled: `dirty` is true by construction here (we're inside the dirty path and
      // disk !== latestContent). A CAS-rejected save can also reach this branch with
      // `pendingSaveSubmitted` still set — the conflict arm awaits `handleExternalChange` before
      // `finally` runs — but it only fires if disk coincidentally equals the submitted content,
      // which is still the correct outcome to adopt in that case too.
      this.baseSHA256 = disk.sha256;
      this.baseContent = disk.content;
      this.pendingMergeUndo = undefined;
      this.banner.style.display = "none";
      this.saveBtn.disabled = false;
      this.pushEditorStateNow();
      return;
    }

    if (this.conflict) {
      // A standing conflict must stay latched until the user explicitly resolves it (Keep mine / Take
      // disk). Routing a further disk-side write through the auto-merge below would diff3 against the
      // base `enterConflictState` adopted — the conflicting disk snapshot itself — so any follow-up
      // edit outside the disputed hunk would read as a clean merge whose disputed hunk is "ours",
      // silently re-enabling Save and letting it overwrite the other writer's version with no
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
    // Explicit, not left over from whatever triggered this: a save() CAS conflict disables Save
    // before routing here, and the merged buffer is still dirty (the original edit is still
    // present, now recombined with disk's change) so Save must stay available.
    this.saveBtn.disabled = false;
    this.pushEditorStateNow();
  }

  /**
   * Schedules the next attempt for a `handleExternalChange` read that failed to run to a decodable
   * conclusion (see the catch branch above) — same floor/doubling/cap backoff shape as root.ts's
   * `scheduleDiffRetry`.
   *
   * Guarded by `fetchToken`/`generation` at fire time (not just captured at schedule time), each
   * covering a different racer:
   *   - `fetchToken`: a fresh `spaces:fileSignature` push event firing its own `handleExternalChange`
   *     call, OR `save()`'s CAS-conflict arm doing the same — either one bumps
   *     `externalChangeFetchToken` the same way this retry's own re-invocation would, since both
   *     routes funnel through this same function.
   *   - `generation`: a newer `loadFile()` moving this pane on to a different file entirely, independent
   *     of whether anything about the external-change flow itself has fired again.
   * Either makes this fire a no-op instead of re-fetching for content nobody is looking at anymore.
   */
  private scheduleExternalChangeRetry(fetchToken: number, generation: number): void {
    const delay = Math.min(
      EXTERNAL_CHANGE_RETRY_FLOOR_MS * 2 ** this.externalChangeRetryFailures,
      EXTERNAL_CHANGE_RETRY_CAP_MS,
    );
    this.externalChangeRetryFailures += 1;
    clearTimeout(this.externalChangeRetryTimer);
    this.externalChangeRetryTimer = setTimeout(() => {
      if (fetchToken !== this.externalChangeFetchToken || generation !== this.openGeneration) return; // superseded while this retry was pending
      void this.handleExternalChange();
    }, delay);
  }

  /** The dismissible "Merged external changes" indicator shown after a clean diff3 auto-merge.
   *  "Dismiss" just hides it (the merge already stands, nothing to undo any more). "Undo" reverts
   *  the buffer to its pre-merge content and enters conflict state against the same disk snapshot
   *  the merge used — "I don't want this decision made for me, let me resolve it manually by hand"
   *  — rather than silently discarding the merge and leaving the buffer's relationship to disk
   *  unresolved. */
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

  private undoMerge(path: string): void {
    if (this.pendingMergeUndo === undefined || path !== this.currentPath) return;
    this.latestContent = this.pendingMergeUndo;
    this.pendingMergeUndo = undefined;
    this.enterConflictState({ content: this.baseContent ?? "", sha256: this.baseSHA256, missing: false });
  }

  /**
   * Common entry point into conflict state from every trigger: an overlapping diff3 result, an
   * explicit Undo of a prior auto-merge, or a dirty buffer whose file was deleted on disk. Freezes
   * the buffer (`this.latestContent`) as "mine" and adopts `disk` as the new CAS baseline
   * (`baseSHA256`/`baseContent`) even though the buffer itself is left untouched — so "Keep mine"'s
   * write CAS-checks against the exact disk state shown in the compare view, and so a second
   * disk-side write while this conflict is still unresolved is detected the same way the first one
   * was (see `resolveConflictKeepMine`).
   */
  private enterConflictState(disk: { content: string; sha256: string | undefined; missing: boolean }): void {
    this.diskMissing = disk.missing;
    // Sentinel for "no real disk hash to CAS against" while missing — inert during conflict (Save
    // is disabled, and `resolveConflictKeepMine` passes `undefined`, the create convention, directly
    // rather than reading this field back).
    this.baseSHA256 = disk.sha256 ?? "";
    this.baseContent = disk.content;
    this.conflict = true;
    this.pendingMergeUndo = undefined; // Undo only applies to a standing auto-merge, not a real conflict
    this.saveBtn.disabled = true;
    this.renderConflictCompareView();
    this.pushEditorStateNow();
  }

  /** Builds the read-only two-way compare (buffer vs. disk) shown while `this.conflict` is true,
   *  reusing the shared `CodeView` instance in its non-edit `"diff"` mode via `parseDiffFromFile`
   *  (which diffs two raw strings directly, unlike diffView.ts's `processFile`, which needs an
   *  existing unified-patch string). `statusOverride` lets a failed "Keep mine" retry refresh just
   *  the banner's status text without rebuilding the diff or the buttons' click handlers. */
  private renderConflictCompareView(statusOverride?: string): void {
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
    text.textContent = statusOverride ?? (this.diskMissing ? `${path} was deleted on disk.` : `${path} changed on disk.`);
    const keepMineBtn = document.createElement("button");
    keepMineBtn.type = "button";
    keepMineBtn.className = "btn primary";
    keepMineBtn.textContent = "Keep mine";
    const takeDiskBtn = document.createElement("button");
    takeDiskBtn.type = "button";
    takeDiskBtn.className = "btn";
    takeDiskBtn.textContent = this.diskMissing ? "Close without saving" : "Take disk";
    takeDiskBtn.addEventListener("click", () => this.resolveConflictTakeDisk());
    // Once this write is issued it cannot be recalled: disk WILL hold the buffer's content when it
    // settles, so "Take disk" stops being a real option the moment this click starts. Leaving it
    // clickable would let a slow write's success arm reverse a later Take-disk choice — disable both
    // buttons synchronously rather than adding a generation/token guard, which would instead let the
    // UI adopt the disk snapshot while the in-flight write replaces disk out from under it (the
    // write's own signature event would then flip the pane back to "mine" ~2s later anyway).
    // `resolveConflictKeepMine`'s `generation`/`fetchToken` guards are right not to catch this case:
    // nothing about a Take-disk click changes either token, by design — it is a pure local adoption.
    // Every settle path re-renders or hides this banner, so the disabled state never outlives the
    // flight: the failure arm re-renders via `renderConflictCompareView` (fresh, enabled buttons),
    // the CAS-conflict arm re-enters via `handleExternalChange` (fresh banner), and the success arm
    // hides the banner.
    keepMineBtn.addEventListener("click", () => {
      keepMineBtn.disabled = true;
      takeDiskBtn.disabled = true;
      void this.resolveConflictKeepMine();
    });

    this.banner.className = "banner conflict";
    this.banner.replaceChildren(text, keepMineBtn, takeDiskBtn);
    this.banner.style.display = "flex";
  }

  /** Conflict compare view's "Keep mine": force-writes the frozen buffer over disk, CAS-checked
   *  against the exact disk snapshot the compare view is showing (or the "create" convention —
   *  `baseSHA256: undefined` — when that snapshot is "deleted", to recreate the file). */
  private async resolveConflictKeepMine(): Promise<void> {
    const path = this.currentPath;
    if (!path) return;
    const generation = this.openGeneration;
    // Fix 2 (round-5): `generation` alone only guards against a NEWER loadFile() — it says nothing about
    // a `handleExternalChange` reconcile completing for the SAME file while this write is still in
    // flight. `handleExternalChange` runs unchanged while already in conflict (see its doc comment),
    // so an external writer changing the file again before this write's response arrives can push a
    // fresh signature event whose reconcile re-enters conflict against that newer disk state (or
    // auto-merges) BEFORE this call's own arms below run — those late arms must not clobber whatever
    // that reconcile already decided. Captured here, alongside `generation`, and re-checked after the
    // write settles (see the arms below). Mirrors `save()`'s identical `fetchToken` guard.
    const fetchToken = this.externalChangeFetchToken;
    const content = this.latestContent ?? "";
    const baseSHA256 = this.diskMissing ? undefined : this.baseSHA256;
    let result: WorkspaceFileWriteResult;
    try {
      result = await this.bridge.workspaceFileWrite(path, content, { baseSHA256, purpose: "editor" });
    } catch (err) {
      if (generation !== this.openGeneration) return; // a later loadFile() already won
      // Fix 2 (round-5): a `handleExternalChange` reconcile for this same file completed while this
      // write was in flight and already decided this file's UI state — this failure is for a write
      // now superseded by that decision, so it must not repaint the compare view over whatever the
      // reconcile already decided. Mirrors `save()`'s equivalent guard.
      if (fetchToken !== this.externalChangeFetchToken) return;
      const message = err instanceof SpacesBridgeError ? err.message : "Failed to save file.";
      this.renderConflictCompareView(message);
      return;
    }
    if (generation !== this.openGeneration) return; // a later loadFile() already won
    if ("conflict" in result) {
      // Deliberately NOT guarded by `fetchToken` (mirrors `save()`'s equivalent arm): this only
      // re-invokes `handleExternalChange()`, which is idempotent against whatever an already-in-flight
      // reconcile did — it always does its own fresh read and re-derives state from scratch, so
      // calling it again here (superseded or not) is harmless.
      //
      // Disk moved again while this conflict was unresolved. Re-run the exact same fresh-read
      // decision this conflict itself came from (see `handleExternalChange`'s doc comment) rather
      // than building a bespoke retry path: it re-fetches disk and re-enters conflict against the
      // newest state, keeping the buffer ("mine") exactly as it was.
      await this.handleExternalChange();
      return;
    }
    // Fix 2 (round-5): a `handleExternalChange` reconcile against newer disk already ran while this
    // write was in flight — committing the older submitted content as clean here would leave the
    // pane stale with no future signature event to correct it (the reconcile consumed the latest
    // one; disk's hash won't change again on its own). The write itself was still a valid CAS write —
    // disk history is correct; there is just newer UI state that owns the pane now. Mirrors `save()`'s
    // equivalent guard.
    if (fetchToken !== this.externalChangeFetchToken) return;
    this.baseSHA256 = result.sha256;
    this.baseContent = content;
    this.latestContent = content;
    this.dirty = false;
    this.conflict = false;
    this.diskMissing = false;
    this.banner.style.display = "none";
    this.loadIntoCodeView(path, content);
    this.pushEditorStateNow();
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
    this.banner.style.display = "none";
    this.loadIntoCodeView(path, content);
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
    this.pendingMergeUndo = undefined;
    this.saveBtn.disabled = true;
    this.banner.style.display = "none";
    this.setPathLabel(path);

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
      this.pendingMergeUndo = undefined;
      this.banner.style.display = "none";
      this.saveBtn.disabled = true; // mirrors a freshly opened clean file: nothing unsaved exists
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
    this.pendingMergeUndo = undefined;
    this.subscribeToFileSignature(state.path);
    if (state.conflict) {
      this.diskMissing = false;
      this.conflict = true;
      this.saveBtn.disabled = true;
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
    this.saveBtn.disabled = false; // mirrors onItemEditChange's post-edit state: unsaved edits exist
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

  private async save(): Promise<void> {
    if (!this.currentPath || this.latestContent === undefined || !this.baseSHA256) return;
    // Re-entrancy guard: a second save() (a queued click, or a programmatic call) can still start
    // before this call's first await yields control back to the DOM, which would submit two CAS
    // writes against the same baseline from the same tab. Disabling the button is the visible half
    // of this; the flag is the half that actually blocks it.
    if (this.saveInFlight) return;
    this.saveInFlight = true;
    this.saveBtn.disabled = true;
    // Captured before the await, alongside `submitted` below: identifies which file this save
    // belongs to. If the user opens a different file before this write resolves, `openGeneration`
    // moves on and this call's completion must not touch `baseSHA256`/`dirty`/`conflict`/the banner/
    // `saveBtn` — all of those now describe the newly opened file, not this one.
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
          baseSHA256: this.baseSHA256,
          purpose: "editor",
        });
      } catch (err) {
        if (generation !== this.openGeneration) return; // a later loadFile() already won; this failure is moot
        // Fix 2 (round-2): a `handleExternalChange` reconcile for this same file completed while this
        // write was in flight and already decided this file's UI state (merge indicator, conflict
        // compare, or a silent clean reload) — this failure is for a write that's now superseded by
        // that decision, so it must not overwrite the banner or re-enable/disable Save out from under
        // it. See `fetchToken`'s doc comment above.
        if (fetchToken !== this.externalChangeFetchToken) return;
        // A rejected write (offline device, timeout, daemon error — e.g. a `SpacesBridgeError` with
        // code `unavailable`) never got a decodable answer from the daemon at all, unlike the
        // `conflict` branch below which is a durable CAS rejection the daemon *did* decode and
        // apply its rules to. Treat it as transient: surface it factually but do NOT set
        // `this.conflict` — a real conflict routes through `handleExternalChange`'s conflict state
        // until the user resolves it; this must not latch the same way, since a retry of the exact
        // same write can still succeed.
        const message = err instanceof SpacesBridgeError ? err.message : "Failed to save file.";
        // "error" styling (not "conflict") keeps this visually distinct from a real CAS conflict.
        this.banner.className = "banner error";
        this.banner.textContent = message;
        this.banner.style.display = "flex";
        // Re-enable Save iff the buffer is still dirty, mirroring the success arm's own rule —
        // `saveInFlight`/`saveBtn.disabled` were both set at entry, so this is what undoes that.
        this.saveBtn.disabled = !this.dirty;
        // Immediate: a save failure is a discrete transition, not a buffer edit.
        this.pushEditorStateNow();
        return;
      }
      if (generation !== this.openGeneration) {
        // A newer loadFile() already moved this pane on to a different file. The write above was still
        // a valid CAS write for the superseded file's own content against its own baseline, so
        // disk is correct either way; there is just no in-memory editor state left for it to update.
        return;
      }
      if ("conflict" in result) {
        // Deliberately NOT guarded by `fetchToken` (Fix 2, round-2): this only re-invokes
        // `handleExternalChange()`, which is idempotent against whatever an already-in-flight
        // reconcile did — it always does its own fresh read and re-derives state from scratch, so
        // calling it again here (superseded or not) is harmless. Route into the same external-change
        // handling a live file-signature push uses: a CAS rejection is itself evidence disk moved
        // since this save's baseline, and `handleExternalChange` always does its own fresh read
        // rather than trusting this result's (possibly already-stale-again)
        // `currentSHA256`/`fileMissing` — see its doc comment. This is the locked auto-merge/
        // conflict-compare model replacing a permanent "save disabled until reopen" latch.
        await this.handleExternalChange();
        return;
      }
      // Fix 2 (round-2): a `handleExternalChange` reconcile for this same file completed while this
      // write was in flight and already decided this file's UI state — this plain-success path must
      // not overwrite it with a now-stale baseline/dirty/banner. See `fetchToken`'s doc comment above.
      if (fetchToken !== this.externalChangeFetchToken) return;
      // The pair (submitted, write hash) is self-consistent by construction — adopt the write's own
      // hash as the next CAS baseline directly rather than re-reading the file. A re-read here would
      // instead race whatever else might write the file (e.g. an agent) between this save and the
      // read: a write landing in that window would make the re-read return someone else's hash
      // paired with this buffer's un-saved-again content, and the next save would then pass CAS and
      // silently overwrite it.
      this.baseSHA256 = result.sha256;
      this.baseContent = submitted;
      // NOT unconditionally clean: the buffer showing in the editor right now is only guaranteed to
      // match disk if nothing was typed during the await. A keystroke that landed while this save was
      // in flight left `latestContent` ahead of `submitted` — that content was never written, so the
      // buffer must stay dirty against the baseline just adopted above (its own next save CAS-checks
      // against this save's hash, which is correct: it is the disk state that content hasn't seen yet).
      this.dirty = this.latestContent !== submitted;
      this.saveBtn.disabled = !this.dirty;
      // Clears a save-failure banner (or a standing merge indicator, now moot) left over from
      // before this successful save.
      this.banner.style.display = "none";
      this.pendingMergeUndo = undefined;
      // Immediate: a successful save is a discrete transition (new baseline, dirty possibly changed).
      this.pushEditorStateNow();
    } finally {
      this.saveInFlight = false;
      this.pendingSaveSubmitted = undefined;
    }
  }
}
