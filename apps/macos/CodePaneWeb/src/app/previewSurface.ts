import { delimiterForPath, parseDelimitedTable } from "./delimitedTable";
import { ImagePixelSize, renderImageStage } from "./imageStage";
import { renderJSONTree } from "./jsonTreeView";
import { MarkdownPreview } from "./markdownPreview";
import { JSONDocument, PreviewKind, PreviewMode } from "./previewMode";
import { TABLE_RETENTION_BUDGET } from "./tableLimits";
import { renderDelimitedTable } from "./tableView";

/**
 * The rendered half of the Editor pane: whichever of the Markdown preview, JSON tree, CSV/TSV
 * table, SVG preview, or image stage the open file's kind and mode call for.
 *
 * It exists so `EditorView` owns one preview object rather than five: the view decides WHICH
 * surface to show (see `previewMode.ts`), and this decides HOW to build it. Every surface is
 * rebuilt from the live buffer on every call, which is what makes the Markdown and SVG previews
 * re-render as the source is typed, and it is why each renderer replaces rather than patches.
 *
 * Every surface is built from one linear pass over a string the editor has already read, and the DOM
 * it builds is capped: the table renders at most 2000 rows and the tree materializes at most 2000
 * children per container, each with a trailing note naming the real count (see `tableView.ts` and
 * `jsonTreeView.ts`). A rebuild happens on every keystroke, so it is the element count that decides
 * whether the pane stays responsive on a large file. The delimited parse is bounded to match: it
 * keeps only the rows and fields the table can show (`TABLE_RETENTION_BUDGET`) while still counting
 * the rest, so a near-10 MiB spreadsheet costs that bounded set of strings rather than every field
 * it holds, and the notes still name the file's real totals. The SVG preview is bounded the same
 * way, by character count rather than element count (see `MAX_PREVIEW_SVG_CHARS`), since what it
 * builds on every render is not a DOM tree but a data URL WebKit has to decode.
 */
export interface PreviewSurfaceCallbacks {
  /** Loads a workspace image for the Markdown preview. Resolves to a `data:` URL, or undefined
   *  when the file cannot be read. */
  loadImage(path: string): Promise<string | undefined>;
  /** A link to another workspace file was clicked in the Markdown preview. */
  onOpenPath(path: string): void;
  /** An image's decoded pixel size, for the open-file bar. */
  onImageSize(size: ImagePixelSize): void;
  /** The preview was scrolled by the user; the view mirrors it onto the source half. */
  onPreviewScrolled(): void;
}

/**
 * The most source characters the SVG preview builds a data URL from. Same figure as
 * `MAX_PREVIEW_SOURCE_CHARS` in `markdownPreview.ts`, and for the same reason: unlike the table and
 * the JSON tree, whose DOM is capped by element count, an SVG preview's cost is in the data URL
 * itself and the decode WebKit runs on it, so a near-10 MiB SVG would allocate and decode a
 * multi-megabyte string on the open and on every keystroke after it with no bound at all. Past this
 * bound the preview renders a muted note instead of the image; the Preview segment stays selectable
 * (the control is not the gate here either), and Source still holds the file.
 */
export const MAX_PREVIEW_SVG_CHARS = 1_000_000;

export class PreviewSurface {
  /** The preview half of the split; the view places it beside the source host. */
  readonly element: HTMLElement;
  private readonly callbacks: PreviewSurfaceCallbacks;
  /** Built on the first Markdown render and reused afterwards, so the pane owns one markdown-it
   *  instance rather than one per document. Its image cache belongs to the document it is showing
   *  and is discarded when a different one is rendered (see `markdownPreview.ts`). */
  private markdown: MarkdownPreview | undefined;
  /** The document this surface last rendered, of any kind. The Markdown preview outlives a switch
   *  to a JSON, table, SVG, plain, or image document, so it only ever sees the Markdown ones and
   *  cannot tell a different document from an edit of the same one by itself; this is what tells
   *  it, so reopening a Markdown document across such a switch reads its images afresh rather than
   *  reusing the data URLs, and the recorded failures, of a document that is no longer open. */
  private documentPath: string | undefined;
  /** Whether `element`'s current child is the Markdown preview, which is the one surface with a
   *  scroll position worth mirroring onto the source. */
  private markdownVisible = false;
  /** Identifies the most recent stage render, so a decoded-size report from an image the pane has
   *  already moved past does not relabel the bar for the one now showing. */
  private imageToken = 0;

  constructor(callbacks: PreviewSurfaceCallbacks) {
    this.callbacks = callbacks;
    this.element = document.createElement("div");
    this.element.className = "editor-preview";
    this.element.id = "code-pane-editor-preview";
  }

  /**
   * Renders the surface `mode` names for a text file, from its live buffer. A mode that shows no
   * rendered surface (`source`, `text`) clears it instead, so nothing stale stays mounted behind a
   * source-only view.
   *
   * `json` is the caller's already-parsed document for a `.json` buffer that parses, and `undefined`
   * for every other kind and for a `.json` buffer that does not. The caller has to parse it anyway
   * to know whether the Tree segment is selectable (`jsonTreeDocument`), so the parse travels here
   * rather than being repeated: a large JSON file is parsed once per keystroke, not twice.
   */
  renderText(
    path: string,
    kind: PreviewKind,
    mode: PreviewMode | undefined,
    content: string,
    json: JSONDocument | undefined,
  ): void {
    this.noteDocument(path);
    switch (kind) {
      case "markdown":
        if (mode === "split" || mode === "preview") {
          this.showMarkdown(path, content);
          return;
        }
        break;
      case "json":
        // The Tree segment is only selectable while the buffer parses (see `resolvePreviewMode`), so
        // a `json` of `undefined` here is the same decision reaching the renderer rather than a
        // second gate.
        if (mode === "tree" && json !== undefined) {
          renderJSONTree(this.scrollHost("json-tree"), json.value);
          return;
        }
        break;
      case "table":
        if (mode === "table") {
          renderDelimitedTable(
            this.scrollHost("preview-table-scroll"),
            parseDelimitedTable(content, delimiterForPath(path), TABLE_RETENTION_BUDGET),
          );
          return;
        }
        break;
      case "svg":
        if (mode === "preview") {
          if (content.length > MAX_PREVIEW_SVG_CHARS) {
            renderPreviewNote(
              this.host(),
              `SVG over ${MAX_PREVIEW_SVG_CHARS.toLocaleString("en-US")} characters is not previewed. Source holds the file.`,
            );
            return;
          }
          // Rendered through the same stage an image uses, from a URL-encoded data URL rather than
          // base64: the source is text, and `encodeURIComponent` carries its UTF-8 exactly.
          renderImageStage(this.host(), `data:image/svg+xml;charset=utf-8,${encodeURIComponent(content)}`, () => {});
          return;
        }
        break;
      case "image":
      case "text":
        break;
    }
    this.clear();
  }

  /** Renders the image file at `path` on the stage, reporting its decoded pixel size to the bar. */
  renderImage(path: string, dataURL: string): void {
    this.noteDocument(path);
    const host = this.host();
    const token = this.imageToken;
    renderImageStage(host, dataURL, (size) => {
      if (token === this.imageToken) this.callbacks.onImageSize(size);
    });
  }

  /** The source line the Markdown preview is scrolled to, or null for every other surface. */
  visibleSourceLine(): number | null {
    return this.markdownVisible ? (this.markdown?.visibleSourceLine() ?? null) : null;
  }

  /** Scrolls the Markdown preview to the block covering `line`; a no-op for every other surface. */
  scrollToSourceLine(line: number): void {
    if (this.markdownVisible) this.markdown?.scrollToSourceLine(line);
  }

  clear(): void {
    this.imageToken += 1;
    this.markdownVisible = false;
    this.markdown?.clear();
    this.element.replaceChildren();
  }

  dispose(): void {
    this.clear();
    // `clear()` only empties the rendered DOM, which is also how a mode switch hides this half. The
    // pane is going away here, so the Markdown preview's outstanding image reads have to stop too.
    this.markdown?.dispose();
    this.markdown = undefined;
    this.documentPath = undefined;
  }

  /** Tells the Markdown preview that a different document has taken the surface, so it discards the
   *  image state scoped to the one before. An edit of the same document is not a switch. */
  private noteDocument(path: string): void {
    if (path === this.documentPath) return;
    this.documentPath = path;
    this.markdown?.beginDocument(path);
  }

  private showMarkdown(path: string, source: string): void {
    if (!this.markdown) {
      this.markdown = new MarkdownPreview({
        loadImage: (imagePath) => this.callbacks.loadImage(imagePath),
        onOpenPath: (openPath) => this.callbacks.onOpenPath(openPath),
      });
      this.markdown.element.addEventListener("scroll", () => this.callbacks.onPreviewScrolled());
    }
    if (!this.markdownVisible) {
      this.element.replaceChildren(this.markdown.element);
      this.markdownVisible = true;
    }
    this.markdown.render(path, source);
  }

  /** The preview's own content element, emptied for a fresh render. */
  private host(): HTMLElement {
    this.imageToken += 1;
    this.markdownVisible = false;
    this.element.replaceChildren();
    return this.element;
  }

  /** A bounded scroll container for a surface that can overflow (the JSON tree, the table), so the
   *  table's sticky header has something to stick to. */
  private scrollHost(className: string): HTMLElement {
    const host = document.createElement("div");
    host.className = className;
    this.host().appendChild(host);
    return host;
  }
}

/** Renders `text` as the muted standalone note the table shows for an empty file
 *  (`preview-table-empty`), reused here for a surface that has nothing to render in place of its
 *  usual content rather than a truncated tail of it. Replaces whatever `host` held. */
function renderPreviewNote(host: HTMLElement, text: string): void {
  host.textContent = "";
  const note = document.createElement("div");
  note.className = "preview-table-empty";
  note.textContent = text;
  host.appendChild(note);
}
