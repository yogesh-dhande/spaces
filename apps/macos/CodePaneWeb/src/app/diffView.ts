import { CodeView, processFile, setLanguageOverride } from "@pierre/diffs";
import type { CodeViewItem, CodeViewOptions, DiffLineAnnotation } from "@pierre/diffs";
import { DiffFileEntry, ReviewCommentSide } from "../bridge/types";
import { CODE_PANE_THEME_NAME, resolveAllowedLanguage } from "../theme";
import {
  AnchoredComment,
  canonicalizeContextAnchor,
  extractDiffLines,
  fromAnnotationSide,
  toAnnotationSide,
} from "./reviewComments";
import { DiffLayout } from "./state";

/** DOM/data hooks `DiffView` calls into for the comment surface — kept as a small interface
 *  rather than a direct `CommentsController` dependency so this file stays a thin adapter to
 *  `@pierre/diffs`, with no comment-semantics knowledge beyond "render this card" / "a line's
 *  gutter was clicked". */
export interface DiffCommentHooks {
  /** Builds the DOM for one line's inline comment card, in whatever expanded/collapsed state the
   *  controller currently wants for this comment. */
  renderCard(anchored: AnchoredComment): HTMLElement;
  /** A gutter-utility click on a real diff line (never fired for binary/truncated placeholder
   *  items — see `buildItem`'s doc comment on why those don't offer the affordance at all). */
  onRequestNewComment(anchor: { filePath: string; side: ReviewCommentSide; lineNumber: number; lineText: string }): void;
}

/**
 * Diff mode's content area: a single `@pierre/diffs` `CodeView` holding every changed file in
 * order, rather than a two-region layout (real diffs in one scrolling area, binary/truncated
 * placeholders in another). One virtualized, uniformly-scrollable list means every file-list-sidebar
 * row — diffable or not — can jump to its file the same way
 * (`scrollTo({ type: "item", id: path })`), and file order always matches the sidebar exactly.
 *
 * `CodeView` owns its own internal scroll/virtualization and needs a bounded-height host (see its
 * `Virtualizer`), so this mounts into a `flex: 1; min-height: 0` element rather than an
 * auto-growing one inside a taller scrolling ancestor.
 *
 * Generic over `AnchoredComment` (Phase 4): `CodeView<AnchoredComment>`'s `enableGutterUtility` +
 * `onGutterUtilityClick` pairing renders the library's own default gutter icon on hover and opens
 * a new draft on click (chosen over the mutually-exclusive `renderGutterUtility`, since a custom
 * icon buys nothing here); `renderAnnotation` renders the comment card DOM for each
 * `CodeViewDiffItem.annotations` entry. Both callbacks are declared with `CodeViewOptions`'s own
 * indexed-access type rather than importing `CodeViewDiffItemContext` (not part of this package's
 * public export surface) — the compiled library appends that context object as each callback's
 * last argument regardless (see `CodeView.js`'s `defineItemSharedCallback`), so this still gets it
 * fully typed.
 */
export class DiffView {
  private codeView: CodeView<AnchoredComment> | undefined;
  private readonly root: HTMLElement;
  private readonly emptyEl: HTMLElement;
  private readonly hooks: DiffCommentHooks;
  private layout: DiffLayout;
  private files: readonly DiffFileEntry[] = [];
  private filesByPath = new Map<string, DiffFileEntry>();
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
   * whenever a file's content identity changes (a live refresh, an error, or a loading placeholder);
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

  constructor(container: HTMLElement, layout: DiffLayout, hooks: DiffCommentHooks) {
    this.layout = layout;
    this.hooks = hooks;
    this.emptyEl = document.createElement("div");
    this.emptyEl.className = "empty-state";
    this.emptyEl.textContent = "No changes";
    this.emptyEl.style.display = "none";
    this.root = document.createElement("div");
    this.root.className = "diff-view-root";
    container.appendChild(this.emptyEl);
    container.appendChild(this.root);
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
    this.generation += 1;
    this.files = files;
    this.filesByPath = new Map(files.map((file) => [file.path, file]));
    this.itemVersions = new Map(files.map((file) => [file.path, this.generation]));
    // A prior `setError` call (see its doc comment) repurposes `emptyEl` for a factual error
    // message; any successful refresh — including one that lands on a genuinely empty diff —
    // supersedes that, so restore the plain "No changes" wording every time this runs rather than
    // only when `files.length === 0` happens to be true again below.
    this.emptyEl.textContent = "No changes";
    this.emptyEl.classList.remove("error");

    if (files.length === 0) {
      this.emptyEl.style.display = "flex";
      this.root.style.display = "none";
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
    const items = this.files.map((file) => this.buildItem(file));
    this.codeView.setItems(items);
    if (preserveScroll) {
      this.codeView.scrollTo({ type: "position", position: scrollTop, behavior: "instant" });
    }
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
      if (!file) continue; // file no longer part of the diff — nothing left in CodeView to update
      this.generation += 1;
      this.itemVersions.set(path, this.generation);
      this.codeView.updateItem(this.buildItem(file));
    }
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
    this.files = [];
    this.filesByPath = new Map();
    this.itemVersions = new Map();
    this.emptyEl.textContent = message;
    this.emptyEl.classList.add("error");
    this.emptyEl.style.display = "flex";
    this.root.style.display = "none";
    this.codeView?.setItems([]);
  }

  /**
   * round-13 Fix 2: synchronously clears the content area to a loading presentation, distinct from
   * both the genuine-empty-diff state (`setFiles([])`) and a durable error (`setError`). Called by
   * `root.ts`'s `dispatch` right before kicking off a scope switch's `refreshDiff`, so the diff area
   * never shows files from a scope other than the toolbar's current pick — a stale-but-labeled-fresh
   * diff is worse than a loading gap. `setFiles`'s next successful call (or `setError`'s failure
   * path) overwrites this the same way it already overwrites a prior `setError` call.
   */
  setLoading(): void {
    this.generation += 1;
    this.files = [];
    this.filesByPath = new Map();
    this.itemVersions = new Map();
    this.emptyEl.textContent = "Loading diff…";
    this.emptyEl.classList.remove("error");
    this.emptyEl.style.display = "flex";
    this.root.style.display = "none";
    this.codeView?.setItems([]);
  }

  scrollToFile(path: string): void {
    this.codeView?.scrollTo({ type: "item", id: path, align: "start", behavior: "smooth" });
  }

  /** Used by the batch tray's row click. Falls back to `scrollToFile` when the tray asks for an
   *  outdated (file-level, `lineNumber: 0`) position — there is no real line to center on. */
  scrollToLine(filePath: string, side: ReviewCommentSide, lineNumber: number): void {
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
    const onGutterUtilityClick: NonNullable<CodeViewOptions<AnchoredComment>["onGutterUtilityClick"]> = (
      range,
      context,
    ) => {
      // Binary/truncated files render as plain-text placeholder ("file"-type) items with no real
      // diff line content to anchor a comment to — the affordance only applies to real diff lines.
      if (context.type !== "diff") return;
      if (range.side === undefined) return; // defensive: a plain click always sets `side`
      this.requestNewComment(context.item.id, fromAnnotationSide(range.side), range.start);
    };
    const renderAnnotation: NonNullable<CodeViewOptions<AnchoredComment>["renderAnnotation"]> = (annotation) =>
      this.hooks.renderCard(annotation.metadata);
    return {
      theme: CODE_PANE_THEME_NAME,
      diffStyle: this.layout,
      enableGutterUtility: true,
      onGutterUtilityClick,
      renderAnnotation,
    };
  }

  private requestNewComment(filePath: string, side: ReviewCommentSide, lineNumber: number): void {
    const file = this.filesByPath.get(filePath);
    const patch = file?.patch ?? "";
    // round-14 Fix 3: a context row's gutter click reports `side: "old"` in split layout even
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
    // this hook (`onGutterUtilityClick`) runs in the middle of `InteractionManager`'s
    // `handleDocumentPointerUp` "gutterSelecting" case, which — after calling us — goes on to call
    // `notifySelectionEnd`/`notifySelectionCommitted`. `notifySelectionCommitted` fires
    // `onLineSelected`, which `CodeView` wraps to call `applySelectedLines` and re-set the very
    // selection we just cleared. That whole pointerup dispatch is one synchronous task, so
    // queuing the clear as a microtask lets it run after the library's re-assert instead of
    // before it.
    queueMicrotask(() => this.codeView?.clearSelectedLines());
  }

  private buildItem(file: DiffFileEntry): CodeViewItem<AnchoredComment> {
    if (file.isBinary) {
      return this.placeholderItem(file.path, "Binary file not shown.");
    }
    if (file.truncated) {
      return this.placeholderItem(file.path, "This file is too large to display in full; showing a placeholder.");
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
    };
  }

  /** Current `CodeViewItem.version` for a file — see `itemVersions`'s doc comment. Falls back to
   *  `generation` for a file `setComments` has never bumped yet (every file gets an `itemVersions`
   *  entry from `setFiles`, so this fallback is only ever exercised defensively). */
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
