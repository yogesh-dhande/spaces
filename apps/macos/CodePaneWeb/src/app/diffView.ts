import { CodeView, processFile, setLanguageOverride } from "@pierre/diffs";
import type { CodeViewItem } from "@pierre/diffs";
import { DiffFileEntry } from "../bridge/types";
import { CODE_PANE_THEME_NAME, resolveAllowedLanguage } from "../theme";
import { DiffLayout } from "./state";

/**
 * Diff mode's content area: a single `@pierre/diffs` `CodeView` holding every
 * changed file in order, rather than a two-region layout (real diffs in one
 * scrolling area, binary/truncated placeholders in another). One
 * virtualized, uniformly-scrollable list means every file-list-sidebar row —
 * diffable or not — can jump to its file the same way
 * (`scrollTo({ type: "item", id: path })`), and file order always matches the
 * sidebar exactly.
 *
 * `CodeView` owns its own internal scroll/virtualization and needs a
 * bounded-height host (see its `Virtualizer`), so this mounts into a
 * `flex: 1; min-height: 0` element rather than an auto-growing one inside a
 * taller scrolling ancestor.
 */
export class DiffView {
  private codeView: CodeView | undefined;
  private readonly root: HTMLElement;
  private readonly emptyEl: HTMLElement;
  private layout: DiffLayout;
  /** Bumped on every `setFiles` call so CodeView's per-item `version` always
   * changes when a file's content changes across a live refresh. Item
   * identity (object references) is rebuilt fresh each call, so relying on
   * reference equality would under-invalidate; a shared generation counter
   * over-invalidates unchanged files instead, which only costs a redundant
   * re-measure, not a correctness bug. */
  private generation = 0;

  constructor(container: HTMLElement, layout: DiffLayout) {
    this.layout = layout;
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

    if (files.length === 0) {
      this.emptyEl.style.display = "flex";
      this.root.style.display = "none";
      this.codeView?.setItems([]);
      return;
    }
    this.emptyEl.style.display = "none";
    this.root.style.display = "";

    if (!this.codeView) {
      this.codeView = new CodeView({ theme: CODE_PANE_THEME_NAME, diffStyle: this.layout });
      this.codeView.setup(this.root);
    }

    const scrollTop = preserveScroll ? this.codeView.getScrollTop() : 0;
    const items = files.map((file) => this.buildItem(file));
    this.codeView.setItems(items);
    if (preserveScroll) {
      this.codeView.scrollTo({ type: "position", position: scrollTop, behavior: "instant" });
    }
  }

  scrollToFile(path: string): void {
    this.codeView?.scrollTo({ type: "item", id: path, align: "start", behavior: "smooth" });
  }

  cleanUp(): void {
    this.codeView?.cleanUp();
  }

  private buildItem(file: DiffFileEntry): CodeViewItem {
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
    return { id: file.path, type: "diff", fileDiff: scopedDiff, version: this.generation };
  }

  private placeholderItem(path: string, message: string): CodeViewItem {
    return {
      id: path,
      type: "file",
      file: { name: path, contents: message, lang: "text", cacheKey: path },
      version: this.generation,
    };
  }
}
