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
  /** Bumped on every `setFiles` call so CodeView's per-item `version` always
   * changes when a file's content changes across a live refresh. Item
   * identity (object references) is rebuilt fresh each call, so relying on
   * reference equality would under-invalidate; a shared generation counter
   * over-invalidates unchanged files instead, which only costs a redundant
   * re-measure, not a correctness bug. `setComments` deliberately does NOT
   * bump this: an annotation-only change (a comment created/edited/deleted)
   * should not force every file to re-highlight, only re-evaluate its
   * `annotations` array — `@pierre/diffs` diffs that array by value
   * independently of `version` (see its exported `areDiffLineAnnotationsEqual`). */
  private generation = 0;

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
   * Re-renders every file's `annotations` from a freshly re-anchored comment list, without
   * bumping `generation` (see its doc comment) or touching scroll position. Called whenever the
   * draft set changes (create/edit/delete/send) and whenever `refreshDiff` re-anchors drafts
   * against a new diff.
   */
  setComments(anchored: readonly AnchoredComment[]): void {
    this.commentsByFile = new Map();
    for (const ac of anchored) {
      if (!ac.position) continue; // file gone from the diff entirely: tray-only, nothing to attach to
      const list = this.commentsByFile.get(ac.comment.filePath) ?? [];
      list.push(ac);
      this.commentsByFile.set(ac.comment.filePath, list);
    }
    if (!this.codeView || this.files.length === 0) return;
    this.codeView.setItems(this.files.map((file) => this.buildItem(file)));
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

  cleanUp(): void {
    this.codeView?.cleanUp();
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
      version: this.generation,
      annotations: this.buildAnnotations(file.path),
    };
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
      version: this.generation,
    };
  }
}
