import MarkdownIt from "markdown-it";
import { resolveWorkspaceReference } from "./workspacePath";

/**
 * Host hooks the preview needs to reach outside itself. Both are narrow on purpose: the preview
 * never touches the bridge, the workspace file cache, or the Editor's own navigation directly, so
 * it stays testable with plain `vi.fn()` stubs and the host stays free to route these however it
 * wants (a cache, a fresh bridge read, whatever `onOpenPath` does to the split layout).
 */
export interface MarkdownPreviewCallbacks {
  /** Loads a workspace image for the preview. Resolves to a `data:` URL, or undefined when the
   *  file cannot be read. */
  loadImage(path: string): Promise<string | undefined>;
  /** A link to another workspace file was clicked; the host opens it in the Editor. */
  onOpenPath(path: string): void;
}

/**
 * The most source lines this renders. Mirrors the table's row cap and the JSON tree's child cap:
 * a Markdown file is bounded only by the editor's 10 MiB read limit, and `md.render()` of one that
 * large builds a DOM big enough to freeze the pane, rebuilt on every keystroke. Splitting the
 * source stays whole (one pass over a string the editor has already read), so the count in the
 * trailing note is the file's real line count and the cap is on what is rendered alone.
 *
 * The line cap alone does not bound a document with few newlines: a generated file can pack
 * several megabytes into a handful of lines (in the extreme, one line), which this cap would hand
 * to `md.render()` whole. `MAX_PREVIEW_SOURCE_CHARS` below bounds that case; the two are evaluated
 * together in `truncateSource`, and whichever produces the shorter prefix is the one that governs.
 */
const MAX_RENDERED_SOURCE_LINES = 5000;

/**
 * The most source characters this renders, alongside the line cap above. `md.render()`'s cost
 * scales with source size, not line count, so a near-10 MiB document with almost no newlines (a
 * single generated line) would otherwise reach the line cap's `lines.slice(0, 5000)` as a no-op
 * and still be handed to markdown-it whole, which can expand into millions of DOM nodes and hang
 * or terminate the web-content process on open and on every edit. Exported so tests can reference
 * it, the same way `MAX_DOCUMENT_IMAGE_BYTES` above is.
 */
export const MAX_PREVIEW_SOURCE_CHARS = 1_000_000;

/**
 * The most distinct workspace images one document resolves. Every resolved reference costs a
 * `workspaceImageRead` of the file's whole bytes and a `data:` URL held for as long as the document
 * stays open, so a document citing thousands of images would read the workspace's entire image set
 * into the pane. Past the cap a reference renders its alt text, exactly as a reference naming no
 * workspace file does, so the document reads consistently either way. The admitted set is kept as
 * the document is retyped, so an edit never demotes an image already on screen.
 */
const MAX_DOCUMENT_IMAGES = 200;

/**
 * The most encoded image bytes one document retains at once, summed across every image it has
 * loaded. The count cap above bounds how many distinct images render, but not how large each one
 * is: a single image can approach the bridge's 10 MiB per-file limit, so `MAX_DOCUMENT_IMAGES`
 * images could otherwise retain roughly 2 GiB of base64 strings, plus their decoded bitmaps, until
 * the document changes, which is enough to terminate the web-content process.
 *
 * Every reference in a document is admitted (and its read dispatched) before any read settles, so
 * `documentImageBytes` is still zero at admission time for a document's first render; admission
 * alone cannot bound the total. The budget is therefore enforced where a read settles: a result
 * that would cross it is discarded rather than cached or rendered, the image renders its alt text
 * exactly as one past `MAX_DOCUMENT_IMAGES` does, and every image still queued for this document is
 * dropped from the queue unfetched (rendering alt text too) with the document's budget marked
 * exhausted, so every later read for this document (queued, still in flight, or not yet requested)
 * is refused the same way. An image already rendered from a read that settled under the budget
 * stays, since exhaustion only gates what has not rendered yet. Exported so tests can reference it.
 */
export const MAX_DOCUMENT_IMAGE_BYTES = 64 * 1024 * 1024;

/**
 * The most decoded pixels one document retains at once, summed across every image it has loaded,
 * alongside `MAX_DOCUMENT_IMAGE_BYTES`. The byte budget bounds an image's *encoded* size, not what
 * its decoded bitmap costs in memory: a web view holds a decoded image at roughly `width * height *
 * 4` bytes (one 32-bit RGBA pixel per source pixel), regardless of how small the encoding is, so an
 * ordinary 20-megapixel JPEG can be a few MiB encoded (well under the byte budget) while decoding to
 * roughly 80 MiB, and four such images pass the byte budget while still being enough to terminate
 * the web-content process. 64,000,000 pixels is about 256 MiB decoded at 4 bytes per pixel. Neither
 * budget bounds the other, so both are enforced independently, using the same admit/demote rules
 * `MAX_DOCUMENT_IMAGE_BYTES` above describes (see `imageBudgetAdmits`). Exported so tests can
 * reference it.
 */
export const MAX_DOCUMENT_IMAGE_PIXELS = 64_000_000;

/**
 * The most image reads in flight at once. The reads run on the daemon's per-workspace serial git
 * queue, shared with the file reads and saves the Editor itself needs, so a document opening with
 * every image at once would put the user's next keystroke's save behind all of them. The rest wait
 * in a FIFO queue, so the images nearest the top of the document are the first to appear.
 */
const MAX_CONCURRENT_IMAGE_LOADS = 4;

/**
 * A heading's id, as a reader writing `[Intro](#intro)` by hand expects it: the heading's text,
 * lowercased and trimmed, with its punctuation dropped and its spaces turned into hyphens. This is
 * GitHub's own slug rule, which is what a Markdown file committed to a repository is written
 * against, so a table of contents authored for the repository's web view works unchanged here.
 * Hyphens and underscores are kept, since they are part of the text a slug is expected to carry;
 * letters and digits of any script are kept for the same reason.
 */
function headingSlug(text: string): string {
  return text
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s_-]/gu, "")
    .replace(/\s+/g, "-");
}

/** What `truncateSource` renders: the (possibly cut) text to parse, and the trailing note to show
 *  for whichever bound cut it, or `undefined` when neither bound was reached. */
interface SourceTruncation {
  text: string;
  note: string | undefined;
}

/** One line break's span in a source string: `start` is where it begins, `end` is the offset of
 *  the line that follows it. `\r\n` is one break (`end` is two past `start`); a lone `\r` or `\n`
 *  not part of a `\r\n` pair is also one break (`end` is one past `start`). This mirrors
 *  markdown-it's own notion of a line ending (it treats all three the same way when computing a
 *  token's `map`), which is what keeps a truncated prefix's `data-source-line` numbering lined up
 *  with what rendering the untruncated source would have produced up to the cut. */
interface LineBreak {
  start: number;
  end: number;
}

/** Finds the next line break at or after `from`, or `undefined` when `source` has none left. Two
 *  native `indexOf` calls rather than a per-character scan: each resumes from the caller's `from`,
 *  so a caller that walks forward break by break (as every scan below does) still does one linear
 *  pass over the string, without ever materializing a lines array the way `split` would. */
function nextLineBreak(source: string, from: number): LineBreak | undefined {
  const nl = source.indexOf("\n", from);
  const cr = source.indexOf("\r", from);
  if (nl === -1 && cr === -1) return undefined;
  if (cr === -1 || (nl !== -1 && nl < cr)) return { start: nl, end: nl + 1 }; // a lone \n
  // The next break starts with \r: a following \n makes it a \r\n pair (one break, two chars); its
  // absence makes it a lone \r (one break, one char).
  return { start: cr, end: source.charCodeAt(cr + 1) === 10 ? cr + 2 : cr + 1 };
}

/**
 * Scans `source` for the offset that ends its first `maxLines` lines: the start of the `maxLines`-th
 * break, i.e. everywhere up to (but not including) the line that break introduces, the same prefix
 * `lines.slice(0, maxLines).join("\n")` produced when lines were `\n`-delimited. `capped` is `true`
 * when that break exists (the source has more than `maxLines` lines); when it does not, `end` is
 * `source.length` and the whole source is the candidate. Bounded by `maxLines` line-break lookups
 * regardless of the source's real size, so a document with many more lines than the cap is never
 * scanned past the cut.
 */
function scanLineCapEnd(source: string, maxLines: number): { end: number; capped: boolean } {
  let pos = 0;
  for (let line = 1; line <= maxLines; line++) {
    const brk = nextLineBreak(source, pos);
    if (brk === undefined) return { end: source.length, capped: false };
    if (line === maxLines) return { end: brk.start, capped: true };
    pos = brk.end;
  }
  return { end: source.length, capped: false }; // unreachable: maxLines is always >= 1
}

/** `source`'s total line count (its break count plus one, since a document with N breaks has N+1
 *  lines whether or not the last one is empty), for the "of N lines" note. A full linear pass, but
 *  only ever taken once truncation has already decided the line cap governs, and never allocates: it
 *  walks break to break exactly like `scanLineCapEnd`, just without stopping at `maxLines`. */
function countTotalLines(source: string): number {
  let pos = 0;
  let breaks = 0;
  for (let brk = nextLineBreak(source, pos); brk !== undefined; brk = nextLineBreak(source, pos)) {
    breaks += 1;
    pos = brk.end;
  }
  return breaks + 1;
}

/**
 * Scans `source` for the longest prefix of whole lines that fits in `maxChars`: the offset of the
 * line break at or after which the cumulative length would first exceed the budget. If the very
 * first line alone already exceeds it, the cut lands at `maxChars` itself (mid-line), since there is
 * no earlier line boundary to stop at.
 *
 * `tookAny` (rather than `end === 0`) is what tells a too-long first line apart from an empty one
 * already kept: an empty first line leaves `end` at 0 too, and an `end === 0` check would then read
 * the *second* line as if it were the first, dropping the leading empty line and shifting every
 * `data-source-line` after it by one.
 */
function scanCharCapEnd(source: string, maxChars: number): { end: number; tookAny: boolean } {
  let pos = 0;
  let end = 0;
  let tookAny = false;
  for (;;) {
    const brk = nextLineBreak(source, pos);
    const lineEnd = brk === undefined ? source.length : brk.start;
    if (lineEnd > maxChars) {
      if (!tookAny) return { end: maxChars, tookAny: false };
      break;
    }
    end = lineEnd;
    tookAny = true;
    if (brk === undefined) break;
    pos = brk.end;
  }
  return { end, tookAny };
}

/**
 * Cuts `source` to whichever of `MAX_RENDERED_SOURCE_LINES` or `MAX_PREVIEW_SOURCE_CHARS` is hit
 * first: the first `MAX_RENDERED_SOURCE_LINES` lines, or the longest prefix of whole lines that
 * fits in the character budget. A document under both bounds is returned whole, with no note. The
 * result is always a literal prefix of `source` (never lines rejoined with a normalized separator),
 * so it starts at line 1 exactly as the untruncated source would, keeping markdown-it's own
 * `data-source-line` numbering correct for `\r\n` and lone-`\r` documents, not just `\n` ones.
 *
 * The two candidates are computed independently (by `scanLineCapEnd` and `scanCharCapEnd`) and the
 * shorter one wins, rather than applying the line cap and then re-checking the character budget
 * against its result: a document with many short lines can be well under the line cap's line count
 * but still cross the character budget on its own (handled below), and a document with few, long
 * lines can cross the line-cap candidate's character count while still being far short of it in
 * lines, so only comparing the two finished candidates picks the one that actually bites first.
 * Neither scan builds a lines array: each is a bounded forward walk over `source`'s line breaks that
 * stops as soon as its own cap is reached, so a multi-megabyte, newline-dense document costs no more
 * than the first `MAX_RENDERED_SOURCE_LINES` breaks and the first `MAX_PREVIEW_SOURCE_CHARS`
 * characters to bound, not a pass over the whole file.
 */
function truncateSource(source: string): SourceTruncation {
  const lineCap = scanLineCapEnd(source, MAX_RENDERED_SOURCE_LINES);

  if (source.length <= MAX_PREVIEW_SOURCE_CHARS) {
    // The character budget can never bite, since even the untruncated source fits it: the line cap,
    // if any, is the only bound in play.
    return {
      text: lineCap.capped ? source.slice(0, lineCap.end) : source,
      note: lineCap.capped ? `Showing first ${MAX_RENDERED_SOURCE_LINES} of ${countTotalLines(source)} lines` : undefined,
    };
  }

  const charCap = scanCharCapEnd(source, MAX_PREVIEW_SOURCE_CHARS);
  const charNote = `Showing the first ${MAX_PREVIEW_SOURCE_CHARS.toLocaleString("en-US")} characters of ${source.length.toLocaleString("en-US")}`;

  if (lineCap.capped && lineCap.end <= charCap.end) {
    return { text: source.slice(0, lineCap.end), note: `Showing first ${MAX_RENDERED_SOURCE_LINES} of ${countTotalLines(source)} lines` };
  }
  return { text: source.slice(0, charCap.end), note: charNote };
}

/**
 * Renders one workspace file as Markdown. Owns exactly one `MarkdownIt` instance, one DOM subtree,
 * and the image/scroll-sync state that goes with the file currently rendered; it is not a pane:
 * the host places `element` and drives `render`/`clear` as the open file and its buffer change.
 */
export class MarkdownPreview {
  /** The scrollable preview element; the host places it in the pane. */
  readonly element: HTMLElement;

  private readonly body: HTMLElement;
  private readonly callbacks: MarkdownPreviewCallbacks;
  private readonly md: MarkdownIt;

  /** Resolved workspace image path -> its loaded outcome. The cache belongs to the document
   *  `documentPath` names: it survives every re-render and every `clear()` of that document (a
   *  keystroke, a mode switch away from the preview and back), and is discarded whole when a
   *  different document is rendered. Bounded by `MAX_DOCUMENT_IMAGES`, since only an admitted path
   *  is ever loaded.
   *
   *  `pixelsCharged` tracks whether this entry's decoded pixels have already been settled against
   *  `documentImagePixels` (see `settleImagePixels`). A read that settles while the preview is
   *  hidden (`clear()`'d for a mode switch to Source, or for another document kind taking the pane)
   *  finds no `<img>` in the DOM to attach its pixel-settling `load` listener to, so `settleImageLoad`
   *  still caches the data URL but leaves `pixelsCharged` false; `attachPendingImages` attaches that
   *  listener itself the first time the cached entry is actually rendered, so every image is charged
   *  (or demoted) exactly once, whether that happens on its first load or on a later return to
   *  Preview. A failed load (`dataUrl: null`) has no pixels to charge and leaves `pixelsCharged`
   *  false, which is never inspected for it since it never reaches the `<img>` branch. */
  private readonly imageCache = new Map<string, { dataUrl: string | null; pixelsCharged: boolean }>();

  /** The document every piece of image state below belongs to, and the path image/link references
   *  resolve against. Deliberately survives `clear()`, which only empties the rendered DOM: the
   *  Editor clears the preview whenever it hides that half, and returning to it must not re-read
   *  images this document already has. */
  private documentPath: string | undefined;

  /**
   * Bumped exactly when the image state below is discarded: a different document taking the
   * preview, or `dispose()` tearing it down. An in-flight load captures it and, if it no longer
   * matches when the load resolves, drops the result rather than caching it against, or painting it
   * into, a document it does not belong to.
   */
  private documentGeneration = 0;

  /** The distinct workspace image paths this document has resolved, in first-seen order, capped at
   *  `MAX_DOCUMENT_IMAGES`. A path in this set renders as an `<img>`; one the cap turned away
   *  renders its alt text. */
  private readonly admittedImagePaths = new Set<string>();

  /** Encoded bytes (the loaded `data:` URL's own length) summed across every image this document
   *  has successfully loaded so far, capped at `MAX_DOCUMENT_IMAGE_BYTES`. Updated only once a load
   *  settles, since an image's size isn't known before then; a load still in flight when a later
   *  image is admitted isn't counted against it. A settle that would push this past the cap is
   *  never added, so this value alone never exceeds `MAX_DOCUMENT_IMAGE_BYTES`. */
  private documentImageBytes = 0;

  /** Decoded pixels (`naturalWidth * naturalHeight`) summed across every image this document has
   *  loaded, capped at `MAX_DOCUMENT_IMAGE_PIXELS`, the sibling counter to `documentImageBytes`
   *  above. An element's natural size isn't known until it has loaded (see `settleImagePixels`), so
   *  this is updated later than `documentImageBytes` for the same image: the byte budget can close
   *  a document before any image's pixel count is ever read. */
  private documentImagePixels = 0;

  /** Set once a settling read would push `documentImageBytes` past `MAX_DOCUMENT_IMAGE_BYTES`, or a
   *  loaded image's natural size would push `documentImagePixels` past `MAX_DOCUMENT_IMAGE_PIXELS`,
   *  and never cleared for the rest of this document's life (only `discardDocumentState` resets it,
   *  alongside both counters). Once set, every image this document has not already rendered (queued,
   *  still in flight, or not yet requested) is refused, regardless of its own size: the budget is
   *  closed for the document rather than re-opened by whichever read happens to settle next and fit. */
  private documentImageBudgetExhausted = false;

  /** Paths queued or in flight for this document, so the same image is never asked for twice: both
   *  within one render pass (a document citing it more than once) and across the keystroke
   *  re-renders that rebuild the DOM while the first request is still outstanding. */
  private readonly pendingImagePaths = new Set<string>();

  /** Admitted paths waiting for a load slot, oldest first. */
  private readonly imageQueue: string[] = [];

  /** The heading ids the rendered document carries, rebuilt on every render. A `#fragment` link is
   *  actionable only while this holds the id it names, which is what keeps a link to a heading that
   *  does not exist from becoming a focus stop that does nothing. */
  private readonly headingIds = new Set<string>();

  /** Loads handed to the host and not yet settled, capped by `MAX_CONCURRENT_IMAGE_LOADS`.
   *  Deliberately not reset when the document changes: a read already in flight is still costing
   *  the daemon a slot, so counting it is what keeps the cap a real bound on concurrent reads
   *  rather than a per-document one. */
  private activeImageLoads = 0;

  constructor(callbacks: MarkdownPreviewCallbacks) {
    this.callbacks = callbacks;
    this.element = document.createElement("div");
    this.element.className = "markdown-preview";
    this.body = document.createElement("div");
    this.body.className = "markdown-body";
    this.element.appendChild(this.body);

    // `html: false` keeps raw HTML in an agent-authored or otherwise untrusted document inert
    // (rendered as escaped text, never injected as markup), the same safe default iOS's
    // `TerminalMarkdownDocument.makeHTML` uses for exactly the same reason. `this.body.innerHTML`
    // is set only from this instance's own `md.render()` output (see `render()` below); nothing
    // else in this class assigns `innerHTML`.
    this.md = new MarkdownIt({ html: false, linkify: true });
    this.installSourceLineAttribution();
    this.installImageRule();
    this.installLinkRule();
    this.element.addEventListener("click", (event) => this.handleClick(event));
    this.element.addEventListener("keydown", (event) => this.handleKeyDown(event));
  }

  /**
   * Re-renders `source` as the preview of the workspace file at `path`. Cheap to call on every
   * keystroke: a same-path render keeps the document's image state whole, so retyping a line
   * neither restarts an image fetch that was about to complete nor re-reads one already loaded.
   * A render with a different path is the file switch that discards it (see `beginDocument`).
   *
   * A file past `MAX_RENDERED_SOURCE_LINES` lines or `MAX_PREVIEW_SOURCE_CHARS` characters, whichever
   * bound is hit first, renders only the prefix that bound allows, followed by a muted note naming
   * the file's real length. This runs on every render, not only on open, since a large document can
   * arrive through an edit as well as an open. The rendered part keeps its `data-source-line`
   * stamps, so scroll sync works over it unchanged; the note itself carries none, so it never
   * enters the ascending-order walk the two scroll-sync methods rely on.
   */
  render(path: string, source: string): void {
    if (path !== this.documentPath) this.beginDocument(path);
    const { text, note } = truncateSource(source);
    // Parsing and rendering as two steps, rather than through `md.render`, is what lets the heading
    // ids be known before the link rule runs: a table of contents at the top of a document names
    // headings that have not been rendered yet, and whether such a link is actionable is decided
    // while its anchor is built.
    const env = {};
    const tokens = this.md.parse(text, env);
    this.assignHeadingIds(tokens, env);
    this.body.innerHTML = this.md.renderer.render(tokens, this.md.options, env);
    if (note !== undefined) {
      const noteEl = document.createElement("div");
      noteEl.className = "markdown-preview-note";
      noteEl.textContent = note;
      this.body.appendChild(noteEl);
    }
    this.attachPendingImages();
  }

  /**
   * The source line number (1-based) the preview is scrolled to, i.e. the top-level block whose
   * band covers the container's top edge. `null` when nothing is rendered, or when every block has
   * already scrolled past that edge.
   *
   * jsdom reports 0 for every layout value, so this reads `getBoundingClientRect()` rather than
   * `offsetTop`/`scrollTop`, so a test can stub the rect of the container and of each block. Blocks
   * are contiguous and in document (and therefore line) order, so walking forward and returning the
   * first block whose bottom edge has not yet scrolled above the container's top edge lands on
   * exactly the block straddling (or immediately below) that top edge, which is the block the
   * user is looking at. This mirrors `DiffView.visiblePosition`'s own `[data-line]` walk.
   */
  visibleSourceLine(): number | null {
    const containerRect = this.element.getBoundingClientRect();
    for (const block of this.attributedElements()) {
      if (block.getBoundingClientRect().bottom > containerRect.top) {
        return this.sourceLineOf(block);
      }
    }
    return null;
  }

  /**
   * Scrolls the preview so the block covering source line `line` (1-based) is at the top.
   *
   * A line before the first attributed block scrolls to the top of the preview instead. Such a line
   * is real source the preview renders nothing for: a document opening with blank lines, a comment,
   * or front matter puts the first block several lines in, so scrolling the source to line 1 would
   * otherwise leave the halves wherever they happened to be. The top is where that part of the
   * document sits. An empty preview has nothing to scroll and is left alone.
   */
  scrollToSourceLine(line: number): void {
    const blocks = this.attributedElements();
    if (blocks.length === 0) return;
    let target: HTMLElement | undefined;
    for (const block of blocks) {
      if (this.sourceLineOf(block) > line) break; // blocks are in ascending line order
      target = block;
    }
    if (target === undefined) {
      this.element.scrollTop = 0;
      return;
    }
    const containerRect = this.element.getBoundingClientRect();
    const rect = target.getBoundingClientRect();
    this.element.scrollTop = this.element.scrollTop + (rect.top - containerRect.top);
  }

  /** Drops the rendered content. The open document's image state is kept, because this is also how
   *  the Editor hides the preview half (a mode switch to Source, a conflict taking the pane): the
   *  images it already loaded must still be there when it comes back. `beginDocument` calls this too,
   *  when opening a different document, but discards the image state alongside it there. */
  clear(): void {
    this.body.replaceChildren();
  }

  /**
   * Tears the preview down for good: the rendered DOM goes, and so does every image the open
   * document still had outstanding. The generation bump makes a load already in flight drop its
   * result, and the emptied queue means it starts nothing behind it, so a document citing more
   * images than the concurrency cap admits stops reading the moment the pane goes away rather than
   * working through the remainder. `clear()` cannot carry this, since it is also how the Editor
   * hides the preview half.
   */
  dispose(): void {
    this.clear();
    this.discardDocumentState();
    this.documentPath = undefined;
  }

  /**
   * Adopts `path` as the open document: drops the previous one's rendered DOM and discards its
   * image state (cache, admitted paths, everything still queued). Loads already in flight are left
   * to settle and are dropped by their own generation check.
   *
   * `render()` calls this itself whenever the path changes, and the host calls it when a document of
   * another kind takes the preview half: this instance outlives that switch, so without dropping the
   * rendered DOM here, a document held open elsewhere in the pane (the JSON tree, the table, an
   * image) would leave the previous document's `<img src="data:...">` nodes, and the bytes they
   * hold, reachable through this instance's own `body` for as long as it stays open.
   */
  beginDocument(path: string): void {
    this.documentPath = path;
    this.clear();
    this.discardDocumentState();
  }

  /** Invalidates every load in flight and drops the image state the open document accumulated. */
  private discardDocumentState(): void {
    this.documentGeneration += 1;
    this.imageCache.clear(); // drops every entry, so its pixelsCharged mark goes with the counters below
    this.admittedImagePaths.clear();
    this.pendingImagePaths.clear();
    this.imageQueue.length = 0;
    this.documentImageBytes = 0;
    this.documentImagePixels = 0;
    this.documentImageBudgetExhausted = false;
  }

  /**
   * Stamps an `id` on every heading token and records it, so a `#fragment` link can resolve against
   * the document it is written in. markdown-it adds no heading ids of its own, and `html: false`
   * leaves an author no way to write one, so without this every in-document link would name
   * nothing.
   *
   * Two headings with the same text get distinct ids, the second one suffixed `-1`, the third `-2`,
   * as GitHub numbers them; the per-base counter starts each search where the last one ended, so a
   * document of repeated headings costs one lookup per heading rather than a scan. A heading whose
   * text slugifies to nothing (punctuation alone) is left without an id, since an empty fragment
   * names no heading anyway.
   */
  private assignHeadingIds(tokens: ReturnType<MarkdownIt["parse"]>, env: object): void {
    this.headingIds.clear();
    const nextSuffix = new Map<string, number>();
    for (let index = 0; index < tokens.length; index += 1) {
      const token = tokens[index]!;
      if (token.type !== "heading_open") continue;
      const inline = tokens[index + 1];
      const text = inline?.children
        ? this.md.renderer.renderInlineAsText(inline.children, this.md.options, env)
        : "";
      const base = headingSlug(text);
      if (base === "") continue;
      let suffix = nextSuffix.get(base) ?? 0;
      let id = suffix === 0 ? base : `${base}-${suffix}`;
      while (this.headingIds.has(id)) {
        suffix += 1;
        id = `${base}-${suffix}`;
      }
      nextSuffix.set(base, suffix + 1);
      this.headingIds.add(id);
      token.attrSet("id", id);
    }
  }

  /**
   * Stamps `data-source-line="<1-based first line>"` on every top-level block's opening tag, which
   * is what `visibleSourceLine`/`scrollToSourceLine` read. Overriding `renderToken` (rather than
   * adding a rule per block type) covers every block kind that falls through to it (paragraphs,
   * headings, lists, blockquotes, tables, `hr`) in one place.
   *
   * Only a `level === 0` token qualifies: nested content (a paragraph inside a blockquote, an item
   * inside a list) would otherwise also carry a line number, and since it renders between its
   * parent's own start and end, attributing it would make the sequence of stamped lines
   * non-monotonic, breaking the ascending-order walk both scroll-sync methods rely on. Only an
   * opening or self-closing tag (`nesting !== -1`) is stamped, so a block's *closing* tag (itself
   * `level === 0` too) doesn't get a second, later attribute for the same block.
   */
  private installSourceLineAttribution(): void {
    const baseRenderToken = this.md.renderer.renderToken.bind(this.md.renderer);
    this.md.renderer.renderToken = (tokens, idx, options) => {
      const token = tokens[idx]!; // the renderer always calls this with a valid index
      if (token.block && token.map && token.nesting !== -1 && token.level === 0) {
        token.attrSet("data-source-line", String(token.map[0] + 1));
      }
      return baseRenderToken(tokens, idx, options);
    };
    // `fence` and `code_block` tokens render through their own dedicated renderer rules
    // (`md.renderer.rules.fence` / `.code_block`) rather than falling through to
    // `renderToken` above, even though they satisfy the same block/map/level conditions: the
    // renderer dispatches a type-named rule ahead of `renderToken` and never calls it once one
    // exists. Left unstamped, a fenced or indented code block's `<pre>` carries no
    // `data-source-line`, so scroll sync resolves a line inside a long code block to whichever
    // stamped block happens to be nearest instead of the code block itself.
    this.installPreLineStamp("fence");
    this.installPreLineStamp("code_block");
  }

  /**
   * Wraps `md.renderer.rules[name]` (both `fence` and `code_block` render a `<pre><code>…`
   * string, never a token stream `renderToken` walks) so the `<pre>` it emits carries
   * `data-source-line`, the same attribute `renderToken` stamps on every other top-level block.
   * The existing rule runs untouched first, so its highlighting/escaping is exactly what
   * markdown-it already produces; this only stamps the attribute onto the `<pre` tag already in
   * its output. Nested content (e.g. a fence inside a blockquote) is left unstamped for the same
   * reason `renderToken` skips it: attributing it would break the ascending-line-order walk
   * `visibleSourceLine`/`scrollToSourceLine` rely on.
   */
  private installPreLineStamp(name: "fence" | "code_block"): void {
    const baseRule = this.md.renderer.rules[name]!;
    this.md.renderer.rules[name] = (tokens, idx, options, env, self) => {
      const token = tokens[idx]!;
      const html = baseRule(tokens, idx, options, env, self);
      if (!token.map || token.level !== 0) return html;
      return html.replace("<pre", `<pre data-source-line="${token.map[0] + 1}"`);
    };
  }

  /**
   * Resolves an image's `src` against the file it's authored in, so a screenshot committed beside a
   * document loads the same way a link to a sibling file does (see `workspacePath.ts`).
   *
   * A reference that resolves gets `data-workspace-src` plus, when this instance already has that
   * path loaded, its cached `src` inline, so a re-render (every keystroke) never flashes an
   * already-loaded image back to blank.
   *
   * A reference that does *not* resolve to a workspace file (an absolute `https:`/`data:` URL, a
   * protocol-relative `//host/path`, a climb above the workspace root) never becomes an `<img>` at
   * all: the alt text takes its place. An `<img>` carrying such a `src` would be fetched by the web
   * view the instant this markup is assigned, and this pane issues no network request of its own:
   * every byte it shows comes through the bridge from the workspace. The placeholder is the same
   * outcome an unreadable workspace image gets, so a document reads consistently either way, and it
   * is also what a reference past `MAX_DOCUMENT_IMAGES` renders as.
   */
  private installImageRule(): void {
    this.md.renderer.rules.image = (tokens, idx, options, env, self) => {
      const token = tokens[idx]!;
      const alt = self.renderInlineAsText(token.children ?? [], options, env);
      const altIndex = token.attrIndex("alt");
      if (altIndex >= 0 && token.attrs) {
        const altAttr = token.attrs[altIndex];
        if (altAttr) altAttr[1] = alt;
      }
      const srcIndex = token.attrIndex("src");
      const srcAttr = srcIndex >= 0 && token.attrs ? token.attrs[srcIndex] : undefined;
      const originalSrc = srcAttr ? srcAttr[1] : "";
      const resolved = resolveWorkspaceReference(this.documentPath ?? "", originalSrc);
      if (resolved === undefined || !this.admitImage(resolved)) {
        return `<span class="markdown-image-alt">${this.md.utils.escapeHtml(alt)}</span>`;
      }
      token.attrSet("data-workspace-src", resolved);
      const cached = this.imageCache.get(resolved);
      if (cached?.dataUrl) {
        token.attrSet("src", cached.dataUrl);
      } else if (srcIndex >= 0 && token.attrs) {
        // No data URL yet (never requested, still in flight, or a recorded failure): drop the
        // markdown-authored relative path so the web view never issues a request of its own for
        // it. `attachPendingImages` below looks for exactly this shape, an
        // `img[data-workspace-src]` with no `src`, to know what still needs loading.
        token.attrs.splice(srcIndex, 1);
      }
      return self.renderToken(tokens, idx, options);
    };
  }

  /** Whether this document may render `path` as an image, or (once already admitted) still may.
   *  The first `MAX_DOCUMENT_IMAGES` distinct paths it resolves may, as long as the document's
   *  budget isn't already exhausted from an earlier settled read; every path past either cap
   *  renders its alt text instead and is never fetched. This is the admission-time rejection for a
   *  document whose budget a previous read already exhausted; the read that actually crosses the
   *  budget is caught later, when it settles, by `settleImageLoad` below, since its size isn't known
   *  until then. Admission here is permanent for as long as the document stays open and the budget
   *  stays open, so retyping it never takes an image that is already on screen away; a path this
   *  document later demotes for exceeding the budget (see `demoteToAltText`) is removed from
   *  `admittedImagePaths` there, so a later reference to it is re-evaluated here rather than treated
   *  as already admitted. */
  private admitImage(path: string): boolean {
    if (this.admittedImagePaths.has(path)) return true;
    if (this.admittedImagePaths.size >= MAX_DOCUMENT_IMAGES) return false;
    if (this.documentImageBudgetExhausted) return false;
    this.admittedImagePaths.add(path);
    return true;
  }

  /** After a render, either queues a load for every workspace image that resolved but has no cached
   *  (or already-attempted) outcome yet, or, for one rendered straight from the cache, attaches the
   *  pixel-settling listener it is still missing: a read that settled while the preview was hidden
   *  cached its data URL without one, since there was no `<img>` in the DOM to attach it to at the
   *  time (see the `imageCache` doc comment). Both cases are the same shape, an `img[data-workspace-src]`
   *  this document has not yet finished settling, so they are handled in one pass rather than two. */
  private attachPendingImages(): void {
    const generation = this.documentGeneration;
    for (const img of this.body.querySelectorAll<HTMLImageElement>("img[data-workspace-src]")) {
      const path = img.dataset.workspaceSrc;
      if (path === undefined) continue;
      if (img.hasAttribute("src")) {
        // Resolved from the cache while rendering. A charged entry needs nothing further (and
        // `attachPixelSettleListener` skips it on its own); an uncharged one is a hidden-preview
        // settle catching up now that it has somewhere to render.
        if (this.imageCache.has(path)) this.attachPixelSettleListener(img, path, generation);
        continue;
      }
      this.requestImage(path);
    }
  }

  private requestImage(path: string): void {
    if (this.imageCache.has(path)) return; // already resolved, success or failure
    if (this.pendingImagePaths.has(path)) return; // already queued or in flight
    this.pendingImagePaths.add(path);
    this.imageQueue.push(path);
    this.pumpImageQueue();
  }

  /** Starts queued loads until the concurrency cap is reached or the queue runs out. Document order
   *  is request order: `attachPendingImages` walks the rendered DOM top to bottom, and the queue is
   *  FIFO. */
  private pumpImageQueue(): void {
    while (this.activeImageLoads < MAX_CONCURRENT_IMAGE_LOADS) {
      const path = this.imageQueue.shift();
      if (path === undefined) return;
      this.startImageLoad(path);
    }
  }

  private startImageLoad(path: string): void {
    const generation = this.documentGeneration;
    this.activeImageLoads += 1;
    this.callbacks.loadImage(path).then((dataUrl) => {
      this.activeImageLoads -= 1;
      // A load that resolves after the preview moved to a different document must neither be cached
      // against that document nor written into a DOM that no longer belongs to this path.
      if (generation === this.documentGeneration) this.settleImageLoad(path, dataUrl);
      // Give the slot back last, not first: a budget-exhausted settle below may drop this
      // document's whole queue, and that drop must land before a queued load is handed the slot
      // this settle just freed. It still runs unconditionally, including for a dropped (stale
      // generation) result, since it bounds the reads this pane has outstanding on the host
      // whether or not the result itself was still wanted.
      this.pumpImageQueue();
    });
  }

  /** Whether admitting `bytes` more encoded bytes and/or `pixels` more decoded pixels would keep
   *  this document within both image budgets, the one decision `settleImageLoad` and
   *  `settleImagePixels` both gate on. A closed budget (either one) refuses everything regardless of
   *  the candidate's own size, per `documentImageBudgetExhausted`'s doc comment. Bytes and pixels are
   *  checked independently since neither bounds the other (see `MAX_DOCUMENT_IMAGE_PIXELS`'s doc
   *  comment): a caller passes 0 for whichever count it cannot measure yet, since a 0 never crosses
   *  its own budget on its own. */
  private imageBudgetAdmits(bytes: number, pixels: number): boolean {
    if (this.documentImageBudgetExhausted) return false;
    return (
      this.documentImageBytes + bytes <= MAX_DOCUMENT_IMAGE_BYTES &&
      this.documentImagePixels + pixels <= MAX_DOCUMENT_IMAGE_PIXELS
    );
  }

  /** Applies one settled read to this document's image state: caches and renders it, or discards it
   *  and closes the document's budget, per the rules on `MAX_DOCUMENT_IMAGE_BYTES` above. A read
   *  that fits the byte budget is not yet known to fit the pixel one, since an element's natural
   *  size isn't known until it loads; that gate runs in `settleImagePixels` once it does, before the
   *  image is kept on screen. Only called for a read whose generation still matches the open
   *  document. */
  private settleImageLoad(path: string, dataUrl: string | undefined): void {
    this.pendingImagePaths.delete(path);
    if (dataUrl === undefined) {
      this.imageCache.set(path, { dataUrl: null, pixelsCharged: false }); // failed: the <img> keeps no src, showing its alt text
      return;
    }
    if (!this.imageBudgetAdmits(dataUrl.length, 0)) {
      // Either this read alone crosses the byte budget, or an earlier settle already closed the
      // document's budget (bytes or pixels; see `documentImageBudgetExhausted`'s doc comment for
      // why every later read is refused rather than re-checked against its own size). Nothing about
      // this result is kept: not cached, not counted, not rendered as an image.
      this.documentImageBudgetExhausted = true;
      this.demoteToAltText(path);
      this.dropQueuedImages();
      return;
    }
    this.documentImageBytes += dataUrl.length;
    this.imageCache.set(path, { dataUrl, pixelsCharged: false });
    // Captured now, not read from `this.documentGeneration` inside the listener below: the pixel
    // gate runs asynchronously, after the element has actually loaded, by which point the preview
    // may already have moved on to a different document (see `startImageLoad`'s own generation
    // check, which this mirrors).
    //
    // No `<img>` matches when this read settles while the preview is hidden (`clear()`'d for a mode
    // switch or another document kind): the pixel-settling listener is left uninstalled, and
    // `attachPendingImages` installs it itself the first time this cached entry actually renders.
    const generation = this.documentGeneration;
    for (const img of this.body.querySelectorAll<HTMLImageElement>("img[data-workspace-src]")) {
      if (img.dataset.workspaceSrc !== path) continue;
      this.attachPixelSettleListener(img, path, generation);
      img.src = dataUrl;
    }
  }

  /** Installs the `load` listener that settles `path`'s decoded-pixel charge once `img`'s natural
   *  size is known, shared by `settleImageLoad` (an image loading for the first time) and
   *  `attachPendingImages` (a cache hit whose earlier settle found no `<img>` to attach to). A path
   *  that already carries a charged cache entry gets no listener at all: `settleImageLoad` attaches
   *  one to every `<img>` sharing that path in one pass (the same document can reference one path
   *  more than once), and a rerender can leave an older, still-decoding element's listener alive
   *  alongside a new one for the same path, so more than one caller can reach this method for a path
   *  that has already settled. Skipping the attach here is the cheap half of that guard; `settleImagePixels`
   *  below carries the other half, for the listener already attached before this document's entry was
   *  marked charged. */
  private attachPixelSettleListener(img: HTMLImageElement, path: string, generation: number): void {
    if (this.imageCache.get(path)?.pixelsCharged) return;
    img.addEventListener("load", () => this.settleImagePixels(path, img, generation), { once: true });
  }

  /** Gates this document's decoded-pixel budget once `img`'s natural size is known (its `load`
   *  event), the same way `settleImageLoad` gates the encoded-byte one: an image whose natural size
   *  would push `documentImagePixels` past `MAX_DOCUMENT_IMAGE_PIXELS` is demoted to alt text before
   *  it renders any further, rather than staying on screen, and the rest of the document's queue is
   *  dropped unfetched, exactly like a byte-budget exhaustion. A stale `generation` (the preview
   *  moved to a different document while this element was still decoding) leaves this document's
   *  state, and that other document's own DOM, untouched.
   *
   *  Returns early, leaving `img` exactly as it is, once the entry is already charged: a path cited
   *  more than once in the same document gets one `load` listener per `<img>`, and the first one to
   *  fire must be the only one that adds to `documentImagePixels`, or the same dimensions get counted
   *  once per copy and can exhaust the budget (and demote in-budget images) on a document that never
   *  actually approached it. */
  private settleImagePixels(path: string, img: HTMLImageElement, generation: number): void {
    if (generation !== this.documentGeneration) return;
    const entry = this.imageCache.get(path);
    if (entry?.pixelsCharged) return;
    const pixels = img.naturalWidth * img.naturalHeight;
    if (!this.imageBudgetAdmits(0, pixels)) {
      this.documentImageBudgetExhausted = true;
      this.demoteToAltText(path);
      this.dropQueuedImages();
      return;
    }
    this.documentImagePixels += pixels;
    // Marks this entry charged so a later render from the cache (`attachPendingImages`) does not
    // attach a second pixel-settling listener to it, and so a listener already attached to another
    // copy of this path (see `attachPixelSettleListener`'s doc comment) is a no-op when it fires. A
    // demoted entry above is left uncharged, but that is moot: `admitImage` refuses it (and every
    // other not-yet-admitted path) for the rest of this document's life once
    // `documentImageBudgetExhausted` is set, so it is never rendered from the cache again.
    if (entry) entry.pixelsCharged = true;
  }

  /** Every path still waiting for a load slot when the document's budget closes is dropped
   *  unfetched, each rendered the same way `demoteToAltText` renders the read that closed the
   *  budget. */
  private dropQueuedImages(): void {
    const queued = this.imageQueue.splice(0, this.imageQueue.length);
    for (const queuedPath of queued) this.demoteToAltText(queuedPath);
  }

  /** Un-admits `path` and renders it as the same alt-text span an admission-time rejection renders,
   *  in place of whichever `<img data-workspace-src>` element the document's current render built
   *  for it (there is always exactly one while this document is on screen, since a path is
   *  requested at most once at a time; see `requestImage`). Removing it from `admittedImagePaths`
   *  is what makes `admitImage` re-evaluate a later reference to this same path against the
   *  (now-exhausted) budget instead of treating it as already admitted. */
  private demoteToAltText(path: string): void {
    this.admittedImagePaths.delete(path);
    this.pendingImagePaths.delete(path);
    for (const img of this.body.querySelectorAll<HTMLImageElement>("img[data-workspace-src]")) {
      if (img.dataset.workspaceSrc !== path) continue;
      const span = document.createElement("span");
      span.className = "markdown-image-alt";
      span.textContent = img.alt;
      img.replaceWith(span);
    }
  }

  /**
   * Renders every link inert: the anchor carries no `href` at all, only a `data-link` naming what
   * this preview resolved it to. An `href` is a navigation the web view can follow without ever
   * reaching a click listener (a middle click, WKWebView's own Open Link menu item, a dragged link),
   * and none of those is something this pane can serve: it is not a browser, and the one navigation
   * it has is opening a workspace file in the Editor. Swallowing the primary click leaves all of
   * them open, so the href is dropped rather than intercepted.
   *
   * `data-link` is set only on a link this preview acts on: a workspace file, or a fragment within
   * the rendered document. A link naming anywhere else keeps its text and its link styling and does
   * nothing, which is exactly what its click already did, and it stays out of the tab order rather
   * than becoming a focus stop with nothing behind it.
   */
  private installLinkRule(): void {
    this.md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
      const token = tokens[idx]!;
      const hrefIndex = token.attrIndex("href");
      const href = hrefIndex >= 0 && token.attrs ? (token.attrs[hrefIndex]?.[1] ?? "") : "";
      if (hrefIndex >= 0 && token.attrs) token.attrs.splice(hrefIndex, 1);
      const target = this.linkTarget(href);
      if (target !== undefined) {
        token.attrSet("data-link", target);
        // Without an `href` the platform no longer treats the anchor as a link, so it needs the role
        // and the tab stop the href would have carried.
        token.attrSet("role", "link");
        token.attrSet("tabindex", "0");
      }
      return self.renderToken(tokens, idx, options);
    };
  }

  /** What activating a link does, resolved once while rendering: a heading within the rendered
   *  document, a workspace file the Editor opens, or nothing at all. A fragment naming no heading of
   *  this document, like a bare `#`, is one of the last: it keeps its text and its link styling and
   *  does nothing, rather than becoming a focus stop with no target behind it. */
  private linkTarget(href: string): string | undefined {
    if (href.startsWith("#")) {
      const id = this.headingFragmentId(href);
      return id === undefined ? undefined : `#${id}`;
    }
    if (this.documentPath === undefined) return undefined;
    return resolveWorkspaceReference(this.documentPath, href);
  }

  /** The heading id a `#fragment` names, or `undefined` when this document has no such heading.
   *  markdown-it percent-encodes what it renders into an href, so the fragment is decoded before it
   *  is matched; a malformed escape decodes to nothing and therefore names no heading, and no
   *  generated slug carries a `%` for it to have named. */
  private headingFragmentId(href: string): string | undefined {
    let id: string;
    try {
      id = decodeURIComponent(href.slice(1));
    } catch {
      return undefined;
    }
    return this.headingIds.has(id) ? id : undefined;
  }

  /**
   * One delegated listener handles every link in the rendered document, since the document is
   * replaced wholesale on every render (per-anchor listeners would need rebinding every keystroke).
   */
  private handleClick(event: MouseEvent): void {
    const anchor = this.activatableLink(event.target);
    if (anchor === undefined) return;
    event.preventDefault();
    this.activateLink(anchor);
  }

  /** Enter on a focused link, which is what the `role`/`tabindex` the render rule stamps promise. */
  private handleKeyDown(event: KeyboardEvent): void {
    if (event.key !== "Enter") return;
    const anchor = this.activatableLink(event.target);
    if (anchor === undefined) return;
    event.preventDefault();
    this.activateLink(anchor);
  }

  private activatableLink(target: EventTarget | null): HTMLElement | undefined {
    const anchor = (target as Element | null)?.closest<HTMLElement>("a[data-link]");
    return anchor && this.element.contains(anchor) ? anchor : undefined;
  }

  private activateLink(anchor: HTMLElement): void {
    const target = anchor.dataset.link ?? "";
    if (target.startsWith("#")) {
      // Only a fragment naming a heading this render stamped is ever given a `data-link`
      // (`linkTarget`), and it is stored already decoded, so this is a lookup of an id the document
      // carries rather than a search that might come up empty.
      const id = target.slice(1);
      Array.from(this.element.querySelectorAll<HTMLElement>("[id]"))
        .find((el) => el.id === id)
        ?.scrollIntoView();
      return;
    }
    this.callbacks.onOpenPath(target);
  }

  private attributedElements(): HTMLElement[] {
    return Array.from(this.body.querySelectorAll<HTMLElement>("[data-source-line]"));
  }

  private sourceLineOf(el: HTMLElement): number {
    return Number(el.dataset.sourceLine);
  }
}
