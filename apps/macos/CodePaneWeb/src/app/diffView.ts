import { CodeView, parseDiffFromFile, processFile, setLanguageOverride } from "@pierre/diffs";
import type { CodeViewItem, CodeViewOptions, DiffLineAnnotation, FileContents, FileDiffMetadata } from "@pierre/diffs";
import { Editor } from "@pierre/diffs/edit";
import { applyPatch, parsePatch, reversePatch } from "diff";
import { DiffFileEntry, ReviewCommentSide } from "../bridge/types";
import { CODE_PANE_THEME_NAME, resolveAllowedLanguage } from "../theme";
import type { AutosaveStatus } from "./autosave";
import {
  AnchoredComment,
  canonicalizeContextAnchor,
  extractDiffLines,
  fromAnnotationSide,
  toAnnotationSide,
} from "./reviewComments";
import { DiffLayout } from "./state";

/** Identifier `DiffView` puts on Pierre's contenteditable while an inline edit session is live.
 *  Exported because the pane scopes its Escape shortcut to keystrokes that came from inside this
 *  element (`root.ts`), which is the same element this file names. */
export const DIFF_EDIT_INPUT_ID = "code-pane-diff-edit-input";
import "../styles/editHeader.css";
import editHeaderCSS from "../styles/editHeader.css?inline";

/** DOM/data hooks `DiffView` calls into for the comment surface — kept as a small interface
 *  rather than a direct `CommentsController` dependency so this file stays a thin adapter to
 *  `@pierre/diffs`, with no comment-semantics knowledge beyond "render this card" / "a line's
 *  gutter was clicked". */
export interface DiffCommentHooks {
  /** Builds the DOM for one line's inline comment card, in whatever expanded/collapsed state the
   *  controller currently wants for this comment. */
  renderCard(anchored: AnchoredComment): HTMLElement;
  /** A gutter-utility click on a real diff line (never fired for binary placeholder
   *  items — see `buildItem`'s doc comment on why those don't offer the affordance at all). */
  onRequestNewComment(anchor: { filePath: string; side: ReviewCommentSide; lineNumber: number; lineText: string }): void;
  /** Clicking a right/new diff line starts the one active inline edit. */
  onRequestEdit?(path: string): void;
  onDiffEditChange?(path: string, content: string): void;
  onResolveDiffEdit?(path: string, action: "keepMine" | "takeDisk" | "closeWithoutSaving"): void;
  /** The "Retry now" control on a failed autosave: write again immediately instead of waiting out
   *  the scheduler's backoff. */
  onRetryDiffEditSave?(path: string): void;
  /** Source-line focus moved within the diff; root coalesces its recovery-state update. */
  onPositionChange?(): void;
}

type DiffViewPosition = { path: string; line: number; side: ReviewCommentSide };

/** A complete Pierre diff hydrated once from the patch and its current editable new side. Keeping
 * this as a value lets callers validate a replacement before discarding an unsaved editor without
 * doing the expensive patch reversal a second time. */
export interface PreparedDiffEdit {
  path: string;
  content: string;
  fileDiff: FileDiffMetadata;
  oldContent: string | null;
}

/**
 * Diff mode's content area: a single `@pierre/diffs` `CodeView` holding every changed file in
 * order, rather than a two-region layout (real diffs in one scrolling area, binary
 * placeholders in another). One virtualized, uniformly-scrollable list means every file-list-sidebar
 * row — diffable or not — can jump to its file the same way
 * (`scrollTo({ type: "item", id: path })`), and file order always matches the sidebar exactly.
 *
 * `CodeView` owns its own internal scroll/virtualization and needs a bounded-height host (see its
 * `Virtualizer`), so this mounts into a `flex: 1; min-height: 0` element rather than an
 * auto-growing one inside a taller scrolling ancestor.
 *
 * Generic over `AnchoredComment`: `CodeView<AnchoredComment>` renders comment cards from each
 * `CodeViewDiffItem.annotations` entry. Pierre owns the native gutter utility and its pointer
 * suppression; post-render decoration supplies its stable automation identifier.
 */
export class DiffView {
  private codeView: CodeView<AnchoredComment> | undefined;
  private readonly root: HTMLElement;
  private readonly emptyEl: HTMLElement;
  /** Transient, retryable inline-edit failures must be visible without replacing the review diff. */
  private readonly editErrorEl: HTMLElement;
  private readonly hooks: DiffCommentHooks;
  private layout: DiffLayout;
  /** A scope switch clears CodeView asynchronously. Until its replacement manifest arrives, old
   * virtualized line nodes must not be sampled into the new scope's durable position. */
  private loading = false;
  private files: DiffFileEntry[] = [];
  private filesByPath = new Map<string, DiffFileEntry>();
  /** Manifest positions make streamed updates a direct replacement instead of a linear lookup. */
  private fileIndexesByPath = new Map<string, number>();
  private commentsByFile = new Map<string, AnchoredComment[]>();
  /** The single monotonic source of every `CodeViewItem.version` ever assigned — by `setFiles`
   * (reseeding every file's entry to a fresh increment of this counter) and by `setComments`
   * (bumping one changed file's own entry to a fresh increment of this same counter; see
   * `itemVersions`'s doc comment). Every assignment site increments `generation` first and stores
   * the result, so no version number is ever issued twice: a version `setComments` hands one file
   * can never collide with a later `setFiles` reseed, or vice versa. That's what makes `@pierre/
   * diffs`' `CodeView.syncItemRecord` short-circuit (`if (item.version === nextItem.version) return
   * false`) a reliable "did anything actually change" check rather than an occasional false
   * negative. `setFiles`/`setError`/`setLoading` also rely on this to change every file's version
   * whenever a file's content identity changes (a live refresh, an error, or loading state);
   * item identity (object references) is rebuilt fresh each call, so relying on reference equality
   * would under-invalidate, while a shared counter instead over-invalidates unchanged files, which
   * only costs a redundant re-measure, not a correctness bug. */
  private generation = 0;
  /** Per-file `CodeViewItem.version`, keyed by file path — reseeded to a freshly bumped
   * `generation` whenever `setFiles` rebuilds the item set (see `buildItem`), then bumped
   * independently per file by `setComments` — also by drawing a fresh increment of `generation`
   * (see its doc comment) — when that file's `annotations` actually change. This exists because
   * `@pierre/diffs`' `CodeView.syncItemRecord` (`dist/components/CodeView.js`) short-circuits
   * `if (item.version === nextItem.version) return false` for both `setItems` and `updateItem` —
   * there is no independent value-diffing of `annotations`, so a changed `annotations` array is
   * silently dropped unless the item's `version` itself changes. A single shared counter bumped on
   * every call would also satisfy that contract, but would mark every file's item dirty (and due
   * for re-measure) on every comment edit; per-file entries let `setComments` touch only the file
   * whose comment list actually changed, while still drawing every entry's value from the same
   * monotonic `generation` counter so a version `setComments` issues can never collide with a later
   * `setFiles` reseed. */
  private itemVersions = new Map<string, number>();
  /** The concrete renderer each rendered item owns. Pierre's `updateItem` only accepts data for
   * the existing renderer, so a transition between a read-only diff and an edit/conflict item
   * rebuilds the rendered item set instead of asking one renderer to become another. */
  private itemTypes = new Map<string, CodeViewItem<AnchoredComment>["type"]>();
  /** The last item record supplied for each visible file. A renderer transition still needs
   * `setItems`, but its untouched records must remain intact so streaming one patch neither
   * re-parses nor re-measures the rest of the diff. */
  private itemsByPath = new Map<string, CodeViewItem<AnchoredComment>>();
  /** Queued/streaming manifest rows belong in the sidebar, not CodeView. Completed patches append
   * in scheduler order, so the virtualizer only creates/measures the newly available item. */
  private readonly renderedPaths = new Set<string>();
  private editing:
    | {
        path: string;
        content: string;
        dirty: boolean;
        /** The owning scheduler's latest autosave status, rendered as this file's header chip. */
        status: AutosaveStatus;
        session: number;
        fileDiff: FileDiffMetadata;
        oldContent: string | null;
        conflict?: { kind: "changed"; diskContent: string } | { kind: "deleted" };
      }
    | undefined;
  /** A dirty editor is user data, not merely a rendering detail. If a live manifest no longer
   * names its path, keep this synthetic file in the CodeView until its edit session ends. */
  private recoveryEditFile: DiffFileEntry | undefined;
  /** Changes only when externally supplied content replaces an edit document. It gives Pierre a
   * new file cache key for disk adoption while ordinary typing keeps the active document intact. */
  private editSessionGeneration = 0;
  private focusedLocation: { path: string; line: number; side: ReviewCommentSide } | undefined;
  /** The initial workspace snapshot names a source location, while a selected manifest row names
   * only a file. Keep the former through patch streaming so revealing the selected row cannot
   * replace an exact restored line with that file's first line. */
  private restoredScrollPosition: DiffViewPosition | undefined;
  /** Keeps the restored file from being moved to its item start by a late selected-file reveal.
   * This ownership lasts for the whole initial stream; the exact line guard may be released as
   * soon as its target post-renders so live viewport sampling can take over. */
  private protectedStreamRevealPath: string | undefined;
  /** A persisted line cannot be restored into a queued file. Keep it until the target's
   * textual diff reports post-render, when Pierre has a concrete line to reveal and focus. */
  private pendingScrollPosition:
    | {
        path: string;
        scrollLine: number | null | undefined;
        scrollSide: ReviewCommentSide | null | undefined;
      }
    | undefined;
  /** Last durable source location. It covers a saved target while its item is queued or
   * virtualized away; a currently visible line always supersedes it. */
  private lastDurableScrollPosition: DiffViewPosition | undefined;
  private pendingFocusedPosition:
    | {
        path: string;
        line: number;
        side: ReviewCommentSide;
      }
    | undefined;

  constructor(container: HTMLElement, layout: DiffLayout, hooks: DiffCommentHooks) {
    this.layout = layout;
    this.hooks = hooks;
    this.emptyEl = document.createElement("div");
    this.emptyEl.className = "empty-state";
    this.emptyEl.textContent = "No changes";
    this.emptyEl.style.display = "none";
    this.root = document.createElement("div");
    this.root.className = "diff-view-root";
    this.root.id = "code-pane-diff-scroll";
    this.editErrorEl = document.createElement("div");
    this.editErrorEl.className = "banner error";
    this.editErrorEl.id = "code-pane-diff-edit-error";
    this.editErrorEl.setAttribute("role", "alert");
    this.editErrorEl.style.display = "none";
    container.appendChild(this.emptyEl);
    container.appendChild(this.root);
    container.appendChild(this.editErrorEl);
  }

  setLayout(layout: DiffLayout): void {
    this.layout = layout;
    this.codeView?.setOptions({ theme: CODE_PANE_THEME_NAME, diffStyle: layout });
  }

  /**
   * Replace the full file set: on a scope change (no scroll to preserve) or
   * on a live refresh from a `diffSignature` event (preserve scroll, since
  * the user may be mid-review when the underlying git state changes).
  */
  setFiles(files: readonly DiffFileEntry[], preserveScroll: boolean): void {
    // A live manifest begins as queued metadata, so rebuilding the file set removes every prior
    // renderer before the replacement patch can reveal it. Capture the source locations while the
    // old virtualized lines still exist, then hand them to the replacement item's post-render path.
    const preservedScrollPosition = preserveScroll ? this.durableScrollPosition() : undefined;
    const preservedFocusedPosition = preserveScroll ? this.focusedLocation : undefined;
    this.generation += 1;
    this.loading = false;
    this.files = [...files];
    this.filesByPath = new Map(this.files.map((file) => [file.path, file]));
    this.fileIndexesByPath = new Map(this.files.map((file, index) => [file.path, index]));
    this.itemVersions = new Map(this.files.map((file) => [file.path, this.generation]));
    if (this.pendingScrollPosition !== undefined && !this.filesByPath.has(this.pendingScrollPosition.path)) {
      this.pendingScrollPosition = undefined;
    }
    if (!preserveScroll || (this.lastDurableScrollPosition !== undefined && !this.filesByPath.has(this.lastDurableScrollPosition.path))) {
      this.lastDurableScrollPosition = undefined;
    }
    if (this.pendingFocusedPosition !== undefined && !this.filesByPath.has(this.pendingFocusedPosition.path)) {
      this.pendingFocusedPosition = undefined;
    }
    if (preservedScrollPosition !== null && preservedScrollPosition !== undefined && this.filesByPath.has(preservedScrollPosition.path)) {
      this.lastDurableScrollPosition = preservedScrollPosition;
      this.pendingScrollPosition = {
        path: preservedScrollPosition.path,
        scrollLine: preservedScrollPosition.line,
        scrollSide: preservedScrollPosition.side,
      };
    }
    if (preservedFocusedPosition !== undefined && this.filesByPath.has(preservedFocusedPosition.path)) {
      this.pendingFocusedPosition = preservedFocusedPosition;
    }
    this.syncRecoveryEditFile();
    // A prior `setError` call (see its doc comment) repurposes `emptyEl` for a factual error
    // message; any successful refresh — including one that lands on a genuinely empty diff —
    // supersedes that, so restore the plain "No changes" wording every time this runs rather than
    // only when `files.length === 0` happens to be true again below.
    this.emptyEl.textContent = "No changes";
    this.emptyEl.classList.remove("error");

    const renderedFiles = this.renderedFiles();
    if (!this.codeView && (this.files.length > 0 || this.recoveryEditFile !== undefined)) {
      this.codeView = new CodeView<AnchoredComment>(this.buildCodeViewOptions());
      this.codeView.setup(this.root);
    }
    if (renderedFiles.length === 0) {
      this.emptyEl.style.display = "flex";
      this.root.style.display = "none";
      this.emptyEl.textContent = this.files.length === 0 ? "No changes" : "Loading diff…";
      this.itemTypes.clear();
      this.itemsByPath.clear();
      this.renderedPaths.clear();
      this.codeView?.setItems([]);
      return;
    }
    this.emptyEl.style.display = "none";
    this.root.style.display = "";

    if (!this.codeView) {
      this.codeView = new CodeView<AnchoredComment>(this.buildCodeViewOptions());
      this.codeView.setup(this.root);
    }

    const scrollTop = preserveScroll ? this.codeView.getScrollTop() : 0;
    this.itemsByPath.clear();
    this.itemTypes.clear();
    this.renderedPaths.clear();
    const items = renderedFiles.map((file) => {
      this.renderedPaths.add(file.path);
      return this.cacheItem(file);
    });
    this.codeView.setItems(items);
    if (preserveScroll) {
      this.codeView.scrollTo({ type: "position", position: scrollTop, behavior: "instant" });
    }
  }

  /** Replaces only one streamed file item. The virtualizer keeps already-rendered patches, comments,
   * and scroll geometry intact while the scheduler advances top-to-bottom. */
  updateFile(file: DiffFileEntry): void {
    const index = this.fileIndexesByPath.get(file.path);
    if (index === undefined || !this.codeView) return;
    this.files[index] = file;
    this.filesByPath.set(file.path, file);
    this.syncRecoveryEditFile();
    if (!this.isRenderedFile(file)) return;
    this.generation += 1;
    this.itemVersions.set(file.path, this.generation);
    const wasRendered = this.renderedPaths.has(file.path);
    const priorType = this.itemTypes.get(file.path);
    const item = this.cacheItem(file);
    if (!wasRendered) {
      this.renderedPaths.add(file.path);
      this.emptyEl.style.display = "none";
      this.root.style.display = "";
      this.codeView.addItem(item);
    } else if (priorType !== item.type) {
      // A rendered item can change between its read-only and edit/conflict renderers. `setItems`
      // recreates that renderer; unchanged records retain their identities and versions.
      this.codeView.setItems(this.cachedRenderedItems());
    } else {
      this.codeView.updateItem(item);
    }
    if (this.editing?.path === file.path && file.patch !== undefined) this.completeEditorAttach(item);
  }

  /** A selected queued file may stream ahead of its manifest neighbors. Appends keep each patch
   * O(1); one reconciliation after that finite stream restores manifest order for later review. */
  finalizeStreamOrder(): void {
    if (!this.codeView) return;
    const visible = this.visiblePosition();
    this.codeView.setItems(this.cachedRenderedItems());
    if (visible !== null) {
      this.codeView.scrollTo({
        type: "line",
        id: visible.path,
        lineNumber: visible.line,
        side: toAnnotationSide(visible.side),
        behavior: "instant",
      });
    }
  }

  beginEdit(path: string, content: string, dirty = false, oldContent?: string | null): boolean {
    const prepared = this.prepareEdit(path, content, oldContent);
    return prepared !== undefined && this.beginPreparedEdit(prepared, dirty);
  }

  /** Activates a complete diff prepared by `prepareEdit`. The preparation belongs to this exact
   * path/content pair, so it is never reused after a disk read or selected file changes. */
  beginPreparedEdit(prepared: PreparedDiffEdit, dirty = false): boolean {
    const { path, content, fileDiff, oldContent } = prepared;
    if (!this.codeView) {
      this.codeView = new CodeView<AnchoredComment>(this.buildCodeViewOptions());
      this.codeView.setup(this.root);
    }
    if (this.editing?.path !== undefined && this.editing.path !== path) this.endEdit(this.editing.path);
    this.editing = { path, content, dirty, status: { kind: "idle" }, fileDiff, oldContent, session: ++this.editSessionGeneration };
    this.syncRecoveryEditFile();
    this.emptyEl.style.display = "none";
    this.root.style.display = "";
    this.generation += 1;
    this.itemVersions.set(path, this.generation);
    const editableFile = this.filesByPath.get(path);
    if (!editableFile) return false;
    const item = this.cacheItem(editableFile);
    // Keep the existing FileDiff renderer: Pierre attaches its editor to that renderer and
    // recomputes the same diff's hunks as the document changes.
    this.renderedPaths.add(path);
    this.codeView.setItems(this.cachedRenderedItems());
    this.completeEditorAttach(item);
    return true;
  }

  /** Hydrates the complete old/new sides exactly once. Callers that need to validate before a
   * destructive transition pass the returned value to `beginPreparedEdit` rather than asking the
   * same patch to be parsed and reverse-applied again. */
  prepareEdit(path: string, content: string, oldContent?: string | null): PreparedDiffEdit | undefined {
    const hydrated = this.createEditableFileDiff(this.filesByPath.get(path), path, content, oldContent);
    return hydrated === undefined ? undefined : { path, content, ...hydrated };
  }

  /** Pierre's stable old comparison side for the active inline edit. */
  comparisonOldContent(path: string): string | null | undefined {
    return this.editing?.path === path ? this.editing.oldContent : undefined;
  }

  /** Rebuilds the single editable item from a disk adoption or clean diff3 merge without creating
   * a second edit session. A fresh session cache key makes Pierre adopt supplied source content
   * instead of retaining the old editor document. Replacing content also exits conflict mode: the
   * caller is supplying a normal editable document, so retaining the old read-only comparison
   * would leave the header and renderer out of sync with the root state. */
  replaceEditContent(path: string, content: string, dirty = true): void {
    if (this.editing?.path !== path || !this.codeView) return;
    const hydrated = this.createEditableFileDiff(this.filesByPath.get(path), path, content, this.editing.oldContent);
    if (hydrated === undefined) return;
    this.editing = { ...this.editing, content, dirty, ...hydrated, conflict: undefined, session: ++this.editSessionGeneration };
    this.generation += 1;
    this.itemVersions.set(path, this.generation);
    const file = this.filesByPath.get(path);
    if (!file) return;
    const priorType = this.itemTypes.get(path);
    const item = this.cacheItem(file);
    if (priorType !== item.type) {
      // Conflict mode is a FileDiff item while normal editing is a File item. Pierre cannot
      // change that renderer through updateItem, so rebuild the cached item list for this one
      // transition just as updateFile does when a streamed file changes type.
      this.codeView.setItems(this.cachedRenderedItems());
    } else {
      this.codeView.updateItem(item);
    }
    this.completeEditorAttach(item);
  }

  /** Swaps an inline source editor for Pierre's read-only disk-versus-buffer comparison. The
   * caller must provide the exact disk content it just read for a changed-file conflict; Keep mine
   * then CAS-writes against that same snapshot instead of a patch fragment or an older baseline. */
  setEditConflict(path: string, conflict: { kind: "changed"; diskContent: string } | { kind: "deleted" }): void {
    if (this.editing?.path !== path || !this.codeView) return;
    this.clearEditorIdentifier();
    this.editing = { ...this.editing, conflict };
    this.generation += 1;
    this.itemVersions.set(path, this.generation);
    // Conflict changes the FileDiff's complete sides and removes its editor. Rebuild the item set
    // so Pierre replaces its renderer rather than retaining the editable attachment.
    const file = this.filesByPath.get(path);
    if (!file) return;
    this.cacheItem(file);
    this.codeView.setItems(this.cachedRenderedItems());
    this.clearEditorIdentifier();
  }

  /** Publishes the owning autosave scheduler's status into this file's header. Only the header
   * changes, so this bumps that one file's item version and pushes a single `updateItem` rather
   * than rebuilding the rendered item set. */
  setEditStatus(path: string, status: AutosaveStatus): void {
    if (this.editing?.path !== path || !this.codeView) return;
    this.editing = { ...this.editing, status };
    this.generation += 1;
    this.itemVersions.set(path, this.generation);
    const file = this.filesByPath.get(path);
    if (!file) return;
    this.codeView.updateItem(this.cacheItem(file));
  }

  endEdit(path: string): void {
    if (this.editing?.path !== path || !this.codeView) return;
    this.clearEditorIdentifier();
    this.editing = undefined;
    const wasRecoveryEdit = this.recoveryEditFile?.path === path;
    this.recoveryEditFile = undefined;
    if (wasRecoveryEdit) this.filesByPath.delete(path);
    this.generation += 1;
    this.itemVersions.set(path, this.generation);
    // Leaving edit returns the active complete-side diff to its patch-backed review diff.
    if (wasRecoveryEdit) {
      this.itemsByPath.delete(path);
      this.itemTypes.delete(path);
      this.renderedPaths.delete(path);
    } else {
      const file = this.filesByPath.get(path);
      if (file && this.isRenderedFile(file)) this.cacheItem(file);
      else {
        this.itemsByPath.delete(path);
        this.itemTypes.delete(path);
        this.renderedPaths.delete(path);
      }
    }
    this.codeView.setItems(this.cachedRenderedItems());
    this.clearEditorIdentifier();
  }

  /**
   * Re-renders each file's `annotations` from a freshly re-anchored comment list, touching only
   * the files whose comment list actually changed (see `annotationListEquals`) and leaving
   * `generation`/scroll position alone. Called whenever the draft set changes (create/edit/delete/
   * send) and whenever `refreshDiff` re-anchors drafts against a new diff.
   *
   * Uses per-item `updateItem` calls rather than one `setItems` pass over every file: `CodeView`
   * only adopts a changed `annotations` array when the item's own `version` changes (see
   * `itemVersions`'s doc comment), so this bumps just the affected file's version instead of a
   * shared counter that would mark every file in the diff dirty for a single comment edit.
   *
   * `forceCardRender` (default `false`) bypasses the `annotationListEquals` short-circuit below, so
   * every file in `touchedPaths` gets a version bump + `updateItem` even when its comment objects
   * and anchors are byte-for-byte identical to last time. `CommentsController.refreshCardsOnly()`
   * needs exactly this: a card's rendered DOM depends on more than its `AnchoredComment` — the Send
   * button's label and disabled state depend on the currently selected agent — so an agent-selection
   * change must force every commented file's card to re-render even though `annotationListEquals`
   * (which only compares comment identity and anchor position) correctly reports no change there.
   */
  setComments(anchored: readonly AnchoredComment[], forceCardRender = false): void {
    const previousByFile = this.commentsByFile;
    this.commentsByFile = new Map();
    for (const ac of anchored) {
      if (!ac.position) continue; // file gone from the diff entirely: tray-only, nothing to attach to
      const list = this.commentsByFile.get(ac.comment.filePath) ?? [];
      list.push(ac);
      this.commentsByFile.set(ac.comment.filePath, list);
    }
    if (!this.codeView || this.files.length === 0) return;

    const touchedPaths = new Set([...previousByFile.keys(), ...this.commentsByFile.keys()]);
    for (const path of touchedPaths) {
      if (!forceCardRender && annotationListEquals(previousByFile.get(path), this.commentsByFile.get(path))) continue;
      const file = this.filesByPath.get(path);
      if (!file || !this.renderedPaths.has(path)) continue; // no rendered item to annotate yet
      this.generation += 1;
      this.itemVersions.set(path, this.generation);
      this.codeView.updateItem(this.cacheItem(file));
    }
  }

  /** Replaces annotations for one completed streamed file. Before its patch is ready there is no
   * CodeView item to redraw; when it arrives `buildItem` reads this map and receives the anchors. */
  updateCommentsForFile(path: string, anchored: readonly AnchoredComment[]): void {
    const previous = this.commentsByFile.get(path);
    if (annotationListEquals(previous, anchored)) return;
    if (anchored.length === 0) this.commentsByFile.delete(path);
    else this.commentsByFile.set(path, [...anchored]);
    if (!this.codeView || !this.renderedPaths.has(path)) return;
    const file = this.filesByPath.get(path);
    if (!file) return;
    this.generation += 1;
    this.itemVersions.set(path, this.generation);
    this.codeView.updateItem(this.cacheItem(file));
  }

  /**
   * Replaces the diff view's content with a factual error message, for a `refreshDiff` pull that
   * failed for a reason retrying can't fix (see root.ts's `refreshDiff` doc comment on permanent
   * vs. transient failures). Reuses the same "nothing to show" `emptyEl` surface as the genuine
   * empty-diff state rather than a separate element, since both are "no file list to render, here's
   * why" — only the wording and an `error` styling hook differ; `setFiles`'s next successful call
   * restores the plain wording.
   */
  setError(message: string): void {
    this.generation += 1;
    this.loading = true;
    this.files = [];
    this.filesByPath = new Map();
    this.itemVersions = new Map();
    this.itemTypes.clear();
    this.itemsByPath.clear();
    this.renderedPaths.clear();
    this.fileIndexesByPath.clear();
    // A failed refresh is a non-preserving reset. Do not let a restore target from the previous
    // scope retarget the first rendered file in a later replacement scope.
    this.restoredScrollPosition = undefined;
    this.protectedStreamRevealPath = undefined;
    this.pendingScrollPosition = undefined;
    this.lastDurableScrollPosition = undefined;
    // The failed manifest must not strand an active editor. Re-promote it as a synthetic file so
    // the user can still see the unsaved buffer, and its autosave status, while the fetch error
    // remains visible above the editor.
    this.syncRecoveryEditFile();
    this.emptyEl.textContent = message;
    this.emptyEl.classList.add("error");
    this.emptyEl.style.display = "flex";
    const renderedFiles = this.renderedFiles();
    if (renderedFiles.length === 0) {
      this.root.style.display = "none";
      this.codeView?.setItems([]);
      return;
    }
    this.root.style.display = "";
    if (!this.codeView) {
      this.codeView = new CodeView<AnchoredComment>(this.buildCodeViewOptions());
      this.codeView.setup(this.root);
    }
    this.renderedPaths.clear();
    const items = renderedFiles.map((file) => {
      this.renderedPaths.add(file.path);
      return this.cacheItem(file);
    });
    this.codeView.setItems(items);
  }

  /**
   * Synchronously clears the content area to a loading presentation, distinct from
   * both the genuine-empty-diff state (`setFiles([])`) and a durable error (`setError`). Called by
   * `root.ts`'s `dispatch` right before kicking off a scope switch's `refreshDiff`, so the diff area
   * never shows files from a scope other than the toolbar's current pick — a stale-but-labeled-fresh
   * diff is worse than a loading gap. `setFiles`'s next successful call (or `setError`'s failure
   * path) overwrites this the same way it already overwrites a prior `setError` call.
   */
  setLoading(): void {
    this.generation += 1;
    this.loading = true;
    this.files = [];
    this.filesByPath = new Map();
    this.itemVersions = new Map();
    this.itemTypes.clear();
    this.itemsByPath.clear();
    this.renderedPaths.clear();
    this.fileIndexesByPath.clear();
    // Loading is a non-preserving scope reset. Do not let a restore target from the previous
    // scope retarget the first rendered file in the replacement scope.
    this.restoredScrollPosition = undefined;
    this.protectedStreamRevealPath = undefined;
    this.pendingScrollPosition = undefined;
    this.lastDurableScrollPosition = undefined;
    // A non-preserving scope reset must not carry a source selection into the new comparison. The
    // active inline editor is independent recovery state and remains promoted below.
    this.focusedLocation = undefined;
    this.pendingFocusedPosition = undefined;
    // A scope refresh must not strand a dirty editor while it replaces the old manifest. Keep
    // only the synthetic recovery item; ordinary diff files were deliberately cleared above so
    // no stale patch remains visible under the loading state.
    this.syncRecoveryEditFile();
    this.emptyEl.textContent = "Loading diff…";
    this.emptyEl.classList.remove("error");
    this.emptyEl.style.display = "flex";
    const renderedFiles = this.renderedFiles();
    if (renderedFiles.length === 0) {
      this.root.style.display = "none";
      this.codeView?.setItems([]);
      return;
    }
    this.root.style.display = "";
    if (!this.codeView) {
      this.codeView = new CodeView<AnchoredComment>(this.buildCodeViewOptions());
      this.codeView.setup(this.root);
    }
    this.renderedPaths.clear();
    const items = renderedFiles.map((file) => {
      this.renderedPaths.add(file.path);
      return this.cacheItem(file);
    });
    this.codeView.setItems(items);
  }

  scrollToFile(path: string): void {
    // An explicit sidebar/quick-open navigation supersedes a startup restoration target. Keep
    // streamed file reveals on `revealStreamedFile`, so transient queue updates cannot clear this
    // guard or overwrite the user's choice.
    this.restoredScrollPosition = undefined;
    this.protectedStreamRevealPath = undefined;
    this.pendingScrollPosition = undefined;
    this.scrollToFileInternal(path);
  }

  /** Scrolls a streamed item without changing the user's/restoration position ownership. */
  private scrollToFileInternal(path: string): void {
    this.codeView?.scrollTo({ type: "item", id: path, align: "start", behavior: "smooth" });
  }

  /** Reveals a queued selected file as its patch arrives, except when this workspace is restoring
   * an exact source location in that same file. */
  revealStreamedFile(path: string): void {
    const restored = this.restoredScrollPosition;
    if (restored?.path === path) {
      this.applyRestoredScrollPosition({ path, scrollLine: restored.line, scrollSide: restored.side });
      return;
    }
    // The exact line guard is released once the target post-renders, but the selected row can be
    // revealed again during final/out-of-order reconciliation. Keep that late item-start scroll
    // from undoing the user's restored/live viewport until the stream explicitly finishes.
    if (this.protectedStreamRevealPath === path) return;
    this.scrollToFileInternal(path);
  }

  /** The initial stream has completed its selected-row reveals. Subsequent user selections use
   * `scrollToFile`'s ordinary file-start behavior. */
  finishRestoredStream(): void {
    this.restoredScrollPosition = undefined;
    this.protectedStreamRevealPath = undefined;
  }

  /** A logical source line survives virtualized content reflow; pixel offsets do not. */
  visibleLine(): number | null {
    return this.visiblePosition()?.line ?? null;
  }

  /** The restore path must name the file whose line was visible, not whichever sidebar row was
   * selected last. Virtualized line nodes carry this stable identity after post-render decoration. */
  visiblePosition(): DiffViewPosition | null {
    if (this.loading || !this.root.isConnected) return null;
    const top = this.root.getBoundingClientRect().top;
    for (const node of this.renderedElements<HTMLElement>("[data-line]")) {
      if (node.getBoundingClientRect().bottom <= top) continue;
      const line = Number(node.dataset.line);
      const path = node.dataset.diffPath;
      const side = node.dataset.diffSide;
      if (path !== undefined && Number.isInteger(line) && line > 0 && (side === "old" || side === "new")) return { path, line, side };
    }
    return null;
  }

  /** Source location safe to persist at a lifecycle boundary. Sidebar selection and review focus
   * are intentionally separate state, so neither can retarget a queued scroll restoration. Until
   * the initial stream finishes, an earlier rendered patch is likewise not the restored viewport. */
  durableScrollPosition(): DiffViewPosition | null {
    if (this.restoredScrollPosition !== undefined) return this.restoredScrollPosition;
    const visible = this.visiblePosition();
    if (visible !== null) {
      this.lastDurableScrollPosition = visible;
      return visible;
    }
    const pending = this.pendingScrollPosition;
    if (pending?.scrollLine !== null && pending?.scrollLine !== undefined && pending.scrollSide !== null && pending.scrollSide !== undefined) {
      return { path: pending.path, line: pending.scrollLine, side: pending.scrollSide };
    }
    return this.lastDurableScrollPosition ?? null;
  }

  focusedLineNumber(): number | null {
    return this.focusedLocation?.line ?? null;
  }

  focusedPosition(): { path: string; line: number; side: ReviewCommentSide } | null {
    return this.focusedLocation ?? null;
  }

  restorePosition(
    scrollPath: string | null | undefined,
    scrollLine: number | null | undefined,
    scrollSide: ReviewCommentSide | null | undefined,
    focusedPath: string | null | undefined,
    focusedLine: number | null | undefined,
    focusedSide: ReviewCommentSide | null | undefined,
  ): void {
    this.focusedLocation = focusedLine === null || focusedLine === undefined || focusedSide === null || focusedSide === undefined
      ? undefined
      : focusedPath === null || focusedPath === undefined
        ? undefined
        : { path: focusedPath, line: focusedLine, side: focusedSide };
    if (scrollPath !== null && scrollPath !== undefined && scrollLine !== null && scrollLine !== undefined && scrollSide !== null && scrollSide !== undefined) {
      const position = { path: scrollPath, scrollLine, scrollSide };
      this.restoredScrollPosition = { path: scrollPath, line: scrollLine, side: scrollSide };
      this.protectedStreamRevealPath = scrollPath;
      this.lastDurableScrollPosition = { path: scrollPath, line: scrollLine, side: scrollSide };
      if (this.itemTypes.get(scrollPath) === "diff") this.applyRestoredScrollPosition(position);
      else this.pendingScrollPosition = position;
    }
    if (this.focusedLocation !== undefined) {
      if (this.itemTypes.get(this.focusedLocation.path) === "diff") this.applyRestoredFocusPosition(this.focusedLocation);
      else this.pendingFocusedPosition = this.focusedLocation;
    }
  }

  /** Used by the batch tray's row click. Falls back to `scrollToFile` when the tray asks for an
   *  outdated (file-level, `lineNumber: 0`) position — there is no real line to center on. */
  scrollToLine(filePath: string, side: ReviewCommentSide, lineNumber: number): void {
    // Comment/tray navigation is an explicit source-location choice, just like selecting a file.
    // It must not be overwritten by a pending position from the initial workspace restore.
    this.restoredScrollPosition = undefined;
    this.protectedStreamRevealPath = undefined;
    this.pendingScrollPosition = undefined;
    if (lineNumber === 0) {
      this.scrollToFile(filePath);
      return;
    }
    this.codeView?.scrollTo({
      type: "line",
      id: filePath,
      lineNumber,
      side: toAnnotationSide(side),
      align: "center",
      behavior: "smooth",
    });
  }

  private buildCodeViewOptions(): CodeViewOptions<AnchoredComment> {
    const renderAnnotation: NonNullable<CodeViewOptions<AnchoredComment>["renderAnnotation"]> = (annotation) =>
      this.hooks.renderCard(annotation.metadata);
    const onLineClick: NonNullable<CodeViewOptions<AnchoredComment>["onLineClick"]> = (event, context) => {
      // Pierre reports a diff click as one `diff-line` event object. CodeView appends the owning
      // item context as the second argument; this shape differs from the selected-range object
      // used by CodeView's selection callbacks, so do not read `side`/`start` from it.
      if (context.type !== "diff" || event.type !== "diff-line") return;
      this.focusedLocation = {
        path: context.item.id,
        line: event.lineNumber,
        side: fromAnnotationSide(event.annotationSide),
      };
      this.hooks.onPositionChange?.();
      if (event.annotationSide !== "additions") return;
      if (this.editing?.path === context.item.id) return;
      this.hooks.onRequestEdit?.(context.item.id);
    };
    const renderHeaderMetadata = (...args: unknown[]): HTMLElement | undefined => {
      const file = args[0] as { name?: string } | undefined;
      const path = file?.name;
      if (!path || this.editing?.path !== path) return undefined;
      const header = document.createElement("div");
      header.className = "diff-edit-header";
      const state = document.createElement("span");
      state.textContent = this.editing.conflict?.kind === "deleted"
        ? "File deleted on disk"
        : this.editing.conflict?.kind === "changed"
          ? "Workspace changed"
          : "Editing";
      header.appendChild(state);
      const spacer = document.createElement("span");
      spacer.className = "sp";
      header.appendChild(spacer);
      // Edits are written by the autosave scheduler, so the header reports what that scheduler is
      // doing instead of offering a Save action. Idle is the one status with nothing to say: the
      // buffer matches disk and this session has not written anything yet.
      const status = this.editing.status;
      if (status.kind !== "idle") {
        const chip = document.createElement("span");
        chip.className = "save-status";
        chip.id = "code-pane-diff-edit-status";
        chip.dataset.state = status.kind;
        chip.textContent = statusChipText(status);
        header.appendChild(chip);
        if (status.kind === "failed") {
          const retry = document.createElement("button");
          retry.type = "button";
          retry.className = "btn ghost";
          retry.id = "code-pane-diff-edit-retry";
          retry.textContent = "Retry now";
          retry.addEventListener("click", () => this.hooks.onRetryDiffEditSave?.(path));
          header.appendChild(retry);
        }
      }
      if (this.editing.conflict !== undefined) {
        const takeDisk = document.createElement("button");
        takeDisk.type = "button";
        takeDisk.className = "btn";
        takeDisk.textContent = this.editing.conflict.kind === "deleted" ? "Close without saving" : "Take disk";
        takeDisk.addEventListener("click", () =>
          this.hooks.onResolveDiffEdit?.(path, this.editing?.conflict?.kind === "deleted" ? "closeWithoutSaving" : "takeDisk"),
        );
        const keepMine = document.createElement("button");
        keepMine.type = "button";
        keepMine.className = "btn primary";
        keepMine.textContent = "Keep mine";
        keepMine.addEventListener("click", () => this.hooks.onResolveDiffEdit?.(path, "keepMine"));
        header.append(takeDisk, keepMine);
      }
      return header;
    };
    return {
      theme: CODE_PANE_THEME_NAME,
      diffStyle: this.layout,
      // Pierre's shadow root adopts only its own stylesheet, so everything the inline edit header
      // needs has to travel through this option: editHeader.css styles that header, and the rule
      // after it hides the native gutter utility. CodeView enables that utility for all renderer
      // types, but file placeholders use the file renderer and inline-edit diffs have no stable
      // patch anchors, so the no-op utility is hidden there while the native callback stays live
      // for ordinary read-only diffs.
      unsafeCSS:
        editHeaderCSS +
        "[data-file] [data-utility-button], :host([data-code-pane-editing]) [data-utility-button] { display: none !important; }",
      enableGutterUtility: true,
      createEditor: (options) => new Editor(options),
      onItemEditChange: (item, file) => {
        if (item.type !== "diff" || this.editing?.path !== item.id || this.editing.conflict !== undefined) return;
        this.editing.content = file.contents;
        this.editing.dirty = true;
        this.clearEditError();
        this.hooks.onDiffEditChange?.(item.id, file.contents);
        this.generation += 1;
        this.itemVersions.set(item.id, this.generation);
        const currentFile = this.filesByPath.get(item.id);
        if (currentFile) this.codeView?.updateItem(this.cacheItem(currentFile));
      },
      onLineClick,
      onGutterUtilityClick: ((range: { start: number; side?: "additions" | "deletions" }, context: { type: string; item: { id: string } }) => {
        if (context.type !== "diff" || range.side === undefined) return;
        if (this.editing?.path === context.item.id) return;
        this.requestNewComment(context.item.id, range.side === "deletions" ? "old" : "new", range.start);
      }) as NonNullable<CodeViewOptions<AnchoredComment>["onGutterUtilityClick"]>,
      renderAnnotation,
      // Metadata augments Pierre's standard filename header. Supplying `renderCustomHeader` even
      // when it returns undefined replaces that header for every rendered file.
      renderHeaderMetadata: renderHeaderMetadata as NonNullable<CodeViewOptions<AnchoredComment>["renderHeaderMetadata"]>,
      onPostRender: ((node: HTMLElement, ...args: unknown[]) => {
        const context = args.at(-1) as { item?: { id?: string } } | undefined;
        const path = context?.item?.id;
        if (path !== undefined) {
          node.toggleAttribute("data-code-pane-editing", this.editing?.path === path && this.editing.conflict === undefined);
          if (this.editing?.path === path && this.editing.conflict === undefined) this.assignEditorIdentifier(node);
          else this.clearEditorIdentifier(node);
          this.decorateNativeGutterUtility(node, path);
          this.decorateRenderedLines(node, path);
          this.retryPendingRestorePosition(path);
        }
      }) as NonNullable<CodeViewOptions<AnchoredComment>["onPostRender"]>,
    };
  }

  private requestNewComment(filePath: string, side: ReviewCommentSide, lineNumber: number): void {
    const file = this.filesByPath.get(filePath);
    const patch = file?.patch ?? "";
    // A context row's gutter click reports `side: "old"` in split layout even
    // though the line is unchanged — canonicalize to the new-side coordinate before it becomes the
    // comment's stored anchor (see `canonicalizeContextAnchor`'s doc comment). A no-op for a real
    // deletion or an already-new-side click.
    const canonical = canonicalizeContextAnchor(patch, side, lineNumber);
    const lineText =
      extractDiffLines(patch).find((line) => line.side === canonical.side && line.lineNumber === canonical.lineNumber)
        ?.text ?? "";
    this.hooks.onRequestNewComment({ filePath, side: canonical.side, lineNumber: canonical.lineNumber, lineText });
    // Left alone, the clicked line stays highlighted forever, the `+` affordance stops following
    // the pointer, and the next gutter click re-anchors to this stale selection instead of the
    // newly clicked line — so we must clear it. But we can't clear it synchronously from here:
    // The utility click runs inside the diff's interactive pre element. Queueing the clear as a
    // microtask keeps it after any selection bookkeeping from that click task.
    queueMicrotask(() => this.codeView?.clearSelectedLines());
  }

  private buildItem(file: DiffFileEntry): CodeViewItem<AnchoredComment> {
    if (this.editing?.path === file.path) {
      if (this.editing.conflict !== undefined) {
        const mine: FileContents = {
          name: file.path,
          contents: this.editing.content,
          cacheKey: `${file.path}:diff-edit:mine:${this.editing.session}`,
          lang: resolveAllowedLanguage(file.path),
        };
        const disk: FileContents | null = this.editing.conflict.kind === "deleted"
          ? null
          : {
              name: file.path,
              contents: this.editing.conflict.diskContent,
              cacheKey: `${file.path}:diff-edit:disk:${this.editing.session}`,
              lang: resolveAllowedLanguage(file.path),
            };
        return {
          id: file.path,
          type: "diff",
          fileDiff: setLanguageOverride(parseDiffFromFile(disk, mine, undefined, false), resolveAllowedLanguage(file.path)),
          version: this.itemVersion(file.path),
        };
      }
      return {
        id: file.path,
        type: "diff",
        fileDiff: this.editing.fileDiff,
        version: this.itemVersion(file.path),
        annotations: this.buildAnnotations(file.path),
        edit: true,
      };
    }
    if (file.isBinary) {
      return this.placeholderItem(file.path, "Binary file not shown.");
    }
    if (file.patch === undefined) {
      return this.placeholderItem(file.path, "Loading patch…");
    }
    const fileDiff = processFile(file.patch ?? "", {
      cacheKey: file.path,
      isGitDiff: true,
      throwOnError: false,
    });
    if (!fileDiff) {
      return this.placeholderItem(file.path, "Unable to parse this file's diff.");
    }
    // Force the language explicitly: auto-detection would otherwise hand the
    // highlighter any of Shiki's ~180 language ids, most of which aren't
    // loaded (see theme/index.ts's resolveAllowedLanguage doc comment).
    const scopedDiff = setLanguageOverride(fileDiff, resolveAllowedLanguage(file.path));
    return {
      id: file.path,
      type: "diff",
      fileDiff: scopedDiff,
      version: this.itemVersion(file.path),
      annotations: this.buildAnnotations(file.path),
      edit: this.editing?.path === file.path,
    };
  }

  private cacheItem(file: DiffFileEntry): CodeViewItem<AnchoredComment> {
    const item = this.buildItem(file);
    this.itemsByPath.set(file.path, item);
    this.itemTypes.set(file.path, item.type);
    return item;
  }

  private cachedRenderedItems(): CodeViewItem<AnchoredComment>[] {
    return this.renderedFiles().map((file) => {
      const item = this.itemsByPath.get(file.path);
      if (item === undefined) throw new Error(`Missing cached CodeView item for ${file.path}`);
      return item;
    });
  }

  private completeEditorAttach(item: CodeViewItem<AnchoredComment>): void {
    const path = item.id;
    const poll = () => {
      if (this.editing?.path !== path || this.editing.conflict !== undefined || !this.codeView) return;
      if (this.codeView.getEditor(path) === undefined) {
        requestAnimationFrame(poll);
        return;
      }
      this.generation += 1;
      this.itemVersions.set(path, this.generation);
      const file = this.filesByPath.get(path);
      if (!file) return;
      const priorType = this.itemTypes.get(path);
      const nextItem = this.cacheItem(file);
      if (priorType !== nextItem.type) {
        // A patch may finish or disappear while Pierre is asynchronously attaching this editor.
        // Recreate a renderer on that type transition instead of asking updateItem to mutate it.
        this.codeView.setItems(this.cachedRenderedItems());
      } else {
        this.codeView.updateItem(nextItem);
      }
      this.assignEditorIdentifierAfterRender(path);
    };
    requestAnimationFrame(poll);
  }

  private assignEditorIdentifierAfterRender(path: string, framesRemaining = 2): void {
    if (this.editing?.path !== path || this.editing.conflict !== undefined || !this.codeView) return;
    if (this.assignEditorIdentifier()) return;
    if (framesRemaining === 0) return;
    // CodeView may replace the item synchronously while its editor surface is mounted by the
    // following render pass. A bounded pair of post-render attempts covers that lifecycle without
    // leaving an unbounded animation-frame loop behind when a test or host declines the attach.
    requestAnimationFrame(() => this.assignEditorIdentifierAfterRender(path, framesRemaining - 1));
  }

  private assignEditorIdentifier(root: HTMLElement = this.root): boolean {
    // Pierre's editor exposes its live surface as a multiline textbox. It sets the
    // contentEditable property rather than an HTML contenteditable attribute, so select the
    // semantic surface that is stable in both the browser and WKWebView DOMs.
    const editorElement = this.renderedElements<HTMLElement>(`[role="textbox"][aria-multiline="true"]`, root)[0];
    if (!editorElement) return false;
    editorElement.id = DIFF_EDIT_INPUT_ID;
    return true;
  }

  /** The identifier belongs to Spaces' active edit contract, not Pierre's renderer lifecycle.
   * Pierre may retain a detached/reused contenteditable while replacing a FileDiff, so clear our
   * identifier before a read-only transition even when that DOM node is not removed immediately. */
  private clearEditorIdentifier(root: HTMLElement = this.root): void {
    for (const editorElement of this.renderedElements<HTMLElement>(`#${DIFF_EDIT_INPUT_ID}`, root)) {
      editorElement.removeAttribute("id");
    }
  }

  private decorateRenderedLines(node: HTMLElement, path: string): void {
    const encodedPath = encodeURIComponent(path);
    for (const line of this.renderedElements<HTMLElement>("[data-line]", node)) {
      const lineNumber = line.dataset.line;
      if (lineNumber === undefined) continue;
      const side = line.closest("[data-deletions]") !== null || line.dataset.lineType === "change-deletion" ? "old" : "new";
      line.id = `code-pane-diff-${side}-line-${encodedPath}-${lineNumber}`;
      line.dataset.diffPath = path;
      line.dataset.diffSide = side;
    }
  }

  private decorateNativeGutterUtility(node: HTMLElement, path: string): void {
    if (this.decorateGutterUtility(node, path) > 0) return;
    // FileDiff emits its post-render hook just before the interaction manager inserts the native
    // SVG control. Observe only this file's shadow root so a later file can never take its id.
    const root = node.shadowRoot;
    if (!root) return;
    const observer = new MutationObserver(() => {
      if (this.decorateGutterUtility(node, path) > 0) observer.disconnect();
    });
    observer.observe(root, { childList: true, subtree: true });
    // The utility's nested shadow tree can be populated after this root's mutation record; a
    // single following task covers that post-mount ordering without touching another file.
    setTimeout(() => {
      this.decorateGutterUtility(node, path);
      observer.disconnect();
    }, 50);
  }

  private decorateGutterUtility(node: HTMLElement, path: string): number {
    const buttons = this.renderedElements<HTMLElement>("[data-utility-button]", node);
    for (const button of buttons) {
      button.id = `code-pane-add-comment-${encodeURIComponent(path)}`;
      button.setAttribute("aria-label", "Add comment");
    }
    return buttons.length;
  }

  /** Rebuild Pierre's complete diff from the current new side. Git streams patch hunks, not full
   * files; reversing the displayed patch first gives `parseDiffFromFile` both complete sides so
   * its editor can preserve and recompute hunks as the document changes. */
  private createEditableFileDiff(
    file: DiffFileEntry | undefined,
    path: string,
    newContent: string,
    suppliedOldContent: string | null | undefined,
  ): { fileDiff: FileDiffMetadata; oldContent: string | null } | undefined {
    if (file?.isBinary) return undefined;
    try {
      const partial = file?.patch === undefined
        ? undefined
        : processFile(file.patch, { cacheKey: file.path, isGitDiff: true, throwOnError: true });
      // A queued manifest row has no patch yet, but restored edits carry the complete persisted
      // baseline explicitly. Accept that supplied old side; a fresh edit still requires a patch
      // so an unappliable partial cannot silently become an empty diff.
      if (file !== undefined && !partial && suppliedOldContent === undefined) return undefined;
      const oldContent = suppliedOldContent !== undefined
        ? suppliedOldContent
        : partial?.type === "new"
          ? null
          : file?.patch === undefined
            ? false
            : applyPatch(newContent, reversePatch(parsePatch(file.patch)[0]!));
      if (oldContent === false) return undefined;
      const oldFile: FileContents | null = oldContent === null
        ? null
        : { name: partial?.prevName ?? file?.oldPath ?? path, contents: oldContent, cacheKey: `${path}:diff-edit:old`, lang: resolveAllowedLanguage(path) };
      const newFile: FileContents = {
        name: path,
        contents: newContent,
        cacheKey: `${path}:diff-edit:new:${this.editSessionGeneration + 1}`,
        lang: resolveAllowedLanguage(path),
      };
      return {
        oldContent,
        fileDiff: setLanguageOverride(parseDiffFromFile(oldFile, newFile, undefined, true), resolveAllowedLanguage(path)),
      };
    } catch {
      return undefined;
    }
  }

  private retryPendingRestorePosition(path: string): void {
    // `onPostRender` also runs for non-diff items. Only the target FileDiff's post-render means
    // Pierre has created the logical line that a saved scroll/focus position can address.
    if (this.itemTypes.get(path) !== "diff") return;
    const scroll = this.pendingScrollPosition;
    if (scroll?.path === path) {
      this.pendingScrollPosition = undefined;
      this.applyRestoredScrollPosition(scroll);
    }
    // Once the target FileDiff has post-rendered, the restore has been applied (either through the
    // pending path above or synchronously when the item was already mounted). Let subsequent live
    // viewport samples represent explicit wheel/trackpad movement instead of keeping the startup
    // location authoritative until the whole stream finishes.
    if (this.restoredScrollPosition?.path === path) this.restoredScrollPosition = undefined;
    const focus = this.pendingFocusedPosition;
    if (focus?.path === path) {
      this.pendingFocusedPosition = undefined;
      this.applyRestoredFocusPosition(focus);
    }
  }

  private applyRestoredScrollPosition(position: {
    path: string;
    scrollLine: number | null | undefined;
    scrollSide: ReviewCommentSide | null | undefined;
  }): void {
    const { path, scrollLine, scrollSide } = position;
    if (scrollLine !== null && scrollLine !== undefined && scrollSide !== null && scrollSide !== undefined) {
      this.lastDurableScrollPosition = { path, line: scrollLine, side: scrollSide };
      this.codeView?.scrollTo({ type: "line", id: path, lineNumber: scrollLine, side: toAnnotationSide(scrollSide), behavior: "instant" });
      this.root.dataset.scrollLine = String(scrollLine);
    }
  }

  private applyRestoredFocusPosition(position: { path: string; line: number; side: ReviewCommentSide }): void {
    const { path, line, side } = position;
    // Restoring focus is distinct from restoring a user line selection. Pierre gives a selected
    // line's gutter utility precedence over pointer hover; keeping the restored line selected would
    // therefore make the comment affordance stay on that stale line after the user moves to another
    // line. The focused DOM line still provides keyboard focus and the durable location remains in
    // `focusedLocation` for persistence.
    this.codeView?.clearSelectedLines({ notify: false });
    requestAnimationFrame(() => {
      const lineElement = this.renderedElements<HTMLElement>("[id]").find(
        (element) => element.id === `code-pane-diff-${side}-line-${encodeURIComponent(path)}-${line}`,
      );
      if (!lineElement) return;
      lineElement.tabIndex = -1;
      lineElement.focus({ preventScroll: true });
    });
  }

  /**
   * Pierre mounts each virtualized file in an open `diffs-container` shadow root. Keep the
   * light-DOM root as the test seam and inspect every descendant open root for the real renderer;
   * nested roots matter because an editable file can place its content surface below another
   * `diffs-container` host. This is required for line identity, durable scroll sampling, focus
   * restoration, and the stable editor identifier.
   */
  private renderedElements<T extends Element>(selector: string, root: HTMLElement = this.root): T[] {
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

  /** Current `CodeViewItem.version` for a file — see `itemVersions`'s doc comment. Every manifest
   *  file receives an entry from `setFiles`; the generation value only covers a defensive absent
   *  entry. */
  private itemVersion(path: string): number {
    return this.itemVersions.get(path) ?? this.generation;
  }

  private buildAnnotations(filePath: string): DiffLineAnnotation<AnchoredComment>[] | undefined {
    const anchored = this.commentsByFile.get(filePath);
    if (!anchored || anchored.length === 0) return undefined;
    return anchored.map((ac) => ({
      side: toAnnotationSide(ac.comment.side),
      lineNumber: ac.position!.lineNumber,
      metadata: ac,
    }));
  }

  private placeholderItem(path: string, message: string): CodeViewItem<AnchoredComment> {
    return {
      id: path,
      type: "file",
      file: { name: path, contents: message, lang: "text", cacheKey: path },
      version: this.itemVersion(path),
    };
  }

  /** Returns the manifest entries plus the one recovery-only editor, which deliberately stays out
   * of the sidebar/manifest scheduler. It is placed first so a refresh cannot strand unsaved text
   * below a long streamed diff. A queued replacement patch also uses this item: its prior verified
   * comparison can still render the live editor after that transfer aborts. */
  private displayedFiles(): readonly DiffFileEntry[] {
    return this.recoveryEditFile === undefined ? this.files : [this.recoveryEditFile, ...this.files];
  }

  /** CodeView receives only ready patch bodies. The one active editor remains visible even when its
   * manifest patch has not arrived, and the synthetic recovery item is always visible. */
  private renderedFiles(): readonly DiffFileEntry[] {
    return this.displayedFiles().filter((file) => this.isRenderedFile(file));
  }

  private isRenderedFile(file: DiffFileEntry): boolean {
    return file.patchState === undefined || file.patchState === "ready" || this.editing?.path === file.path;
  }

  private syncRecoveryEditFile(): void {
    const editing = this.editing;
    const manifestFile = editing === undefined ? undefined : this.files.find((file) => file.path === editing.path);
    if (!editing || (manifestFile !== undefined && this.isRenderedFile(manifestFile))) {
      this.recoveryEditFile = undefined;
      return;
    }
    this.recoveryEditFile = {
      path: editing.path,
      status: "modified",
      isBinary: false,
      patchState: "ready",
    };
    this.filesByPath.set(editing.path, this.recoveryEditFile);
    if (!this.itemVersions.has(editing.path)) this.itemVersions.set(editing.path, this.generation);
  }

  /** Keeps retryable file-read/write failures visible without replacing the surrounding review. */
  showEditError(message: string): void {
    this.editErrorEl.textContent = message;
    this.editErrorEl.style.display = "flex";
  }

  clearEditError(): void {
    this.editErrorEl.style.display = "none";
    this.editErrorEl.textContent = "";
  }
}

/**
 * Value-equality check for one file's comment list across two `setComments` calls: same length,
 * with each entry's `comment` object reference unchanged and the same anchored `position`. Object
 * references are stable across a re-anchor unless the underlying comment was actually replaced
 * (`CommentsController.doPersistBody` swaps in the daemon's response object on every successful
 * persist, including a body-only edit), so this catches every case that needs the card re-rendered:
 * comments added/removed, a re-anchor moving a comment's line, and a body/edit-count change.
 */
function annotationListEquals(a: readonly AnchoredComment[] | undefined, b: readonly AnchoredComment[] | undefined): boolean {
  if (a === b) return true;
  if (a === undefined || b === undefined || a.length !== b.length) return false;
  return a.every((ac, index) => {
    const other = b[index]!;
    return ac.comment === other.comment && ac.position!.lineNumber === other.position!.lineNumber && ac.position!.outdated === other.position!.outdated;
  });
}

/** The inline editor's one-line autosave report. `failed` names both the reason and how long the
 * scheduler will wait before writing again, so the "Retry now" button beside it is a shortcut
 * rather than the only way back. */
function statusChipText(status: AutosaveStatus): string {
  switch (status.kind) {
    case "dirty":
      return "Unsaved";
    case "saving":
      return "Saving…";
    case "saved":
      return "Saved";
    case "failed":
      return `Save failed: ${status.reason} · retry in ${Math.ceil(status.retryInMs / 1000)} s`;
    case "blocked":
      return `Save blocked: ${status.reason}`;
    case "idle":
      return "";
  }
}
