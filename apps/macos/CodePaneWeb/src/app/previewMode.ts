/**
 * What kind of preview a file gets, which segments its mode control offers, and which mode it
 * opens in. Pure decisions, no DOM: the open-file bar's one shared segmented control
 * (`modeControl.ts`) and `EditorView` both read them from here, so the control can never offer a
 * segment the view cannot render.
 *
 * Every rule here is keyed off the file's extension alone, except the JSON tree, which additionally
 * requires the content to parse (see `jsonTreeDocument`).
 */

import { JSONValue, parseJSONDocument } from "./jsonDocument";

/** The preview families a file can belong to. `text` is everything with no preview at all: it gets
 *  no mode control, only the source editor Editor mode has always shown. */
export type PreviewKind = "markdown" | "json" | "image" | "svg" | "table" | "text";

/**
 * A mode the shared control can select. The names are shared across kinds where the meaning is the
 * same, so `EditorView` branches on the mode rather than on the pair (kind, mode):
 *  - `source` and `text` both show the editable source. They are distinct because the label differs
 *    (`Source` beside a rendered document, `Text` beside a structured view of the same bytes) and
 *    the label is what the user reads.
 *  - `preview`, `tree`, and `table` each name one rendered surface.
 *  - `split` shows source and preview side by side, and only Markdown has it.
 */
export type PreviewMode = "split" | "source" | "preview" | "tree" | "text" | "table";

/** One segment of the shared control. A disabled segment is shown rather than hidden: the JSON tree
 *  being unavailable is information about the file (it does not parse), not an absent feature. */
export interface PreviewModeSegment {
  mode: PreviewMode;
  label: string;
  enabled: boolean;
}

/**
 * The image types the Editor opens on its image stage, and the media type each is served as. This
 * set is mirrored by `CodePaneBridge.imageMediaType(forPath:)` on the Swift side, which is what
 * actually narrows the bridge's binary-file refusal; a type added here without adding it there
 * would offer an image the bridge still refuses to read.
 */
const IMAGE_MEDIA_TYPES: Readonly<Record<string, string>> = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  bmp: "image/bmp",
};

/** The lowercased extension of `path`, or `""` for a name with no dot in its last segment. A
 *  dotfile with no extension (`.gitignore`) has none: its leading dot starts the name. */
export function fileExtension(path: string): string {
  const name = path.slice(path.lastIndexOf("/") + 1);
  const dot = name.lastIndexOf(".");
  if (dot <= 0) return "";
  return name.slice(dot + 1).toLowerCase();
}

/** The media type an image path is served as, or `undefined` when the path is not one of the six
 *  image types the stage shows. */
export function imageMediaType(path: string): string | undefined {
  return IMAGE_MEDIA_TYPES[fileExtension(path)];
}

/**
 * The preview family `path` belongs to.
 *
 * `jsonc` and `jsonl` are JSON-family on purpose: their control offers the same two segments, with
 * Tree permanently disabled (see `jsonTreeDocument`), which says "this is JSON-ish, and the tree
 * needs strict JSON" rather than silently treating the file as plain text.
 */
export function previewKind(path: string): PreviewKind {
  switch (fileExtension(path)) {
    case "md":
    case "markdown":
      return "markdown";
    case "json":
    case "jsonc":
    case "jsonl":
      return "json";
    case "svg":
      return "svg";
    case "csv":
    case "tsv":
      return "table";
    default:
      return imageMediaType(path) === undefined ? "text" : "image";
  }
}

/**
 * The document the JSON tree renders for `path`'s current content, or `undefined` when it has no
 * tree: strict JSON only, and only for a `.json` file. JSONC (comments, trailing commas) and JSONL
 * (one document per line) are refused by extension rather than by parse result, so a single-line
 * `.jsonl` file that happens to parse does not get a tree that the next appended line would take
 * away.
 *
 * It answers with the parsed document rather than a yes/no because the same parse decides both
 * things a render needs: whether the Tree segment is selectable, and what the tree is built from.
 * `EditorView` calls this once per render and hands the result to `PreviewSurface`, so a `.json`
 * file is parsed once per keystroke rather than twice.
 */
export function jsonTreeDocument(path: string, content: string): JSONDocument | undefined {
  if (fileExtension(path) !== "json") return undefined;
  return parseStrictJSON(content);
}

/** A parsed strict-JSON document, boxed so a file whose whole content is `null` is distinguishable
 *  from a file that does not parse. */
export interface JSONDocument {
  value: JSONValue;
}

/**
 * Parses strict JSON, boxed so a file whose whole content is `null` is distinguishable from a file
 * that does not parse.
 *
 * Parsed by `jsonDocument.ts` rather than `JSON.parse` because the tree is a read-only view of what
 * the file says: `JSON.parse` rounds `9007199254740993` to `9007199254740992` and rewrites `1.00`
 * as `1` before the tree ever sees them, and neither is recoverable afterwards. That parser accepts
 * exactly the grammar `JSON.parse` accepts and throws a `JSONSyntaxError` for everything else. It
 * also throws a `JSONDepthError` for a document nested deeper than `MAX_NESTING_DEPTH` allows, a
 * distinct outcome (the document may otherwise be well-formed) that this catches the same broad way
 * as a syntax error, since either one leaves the Tree segment with nothing it can show: a document
 * that does not parse, and one nested deeper than the parser will recurse into, both disable Tree
 * and leave Text holding the file.
 */
export function parseStrictJSON(content: string): JSONDocument | undefined {
  try {
    return { value: parseJSONDocument(content) };
  } catch {
    return undefined;
  }
}

/**
 * The segments the shared control shows for `kind`, in display order. An empty list means the
 * control is not shown at all: a plain text file has one way to be looked at, and an image has one
 * too (its bytes are not text, so there is nothing to switch to).
 */
export function previewModeSegments(kind: PreviewKind, options: { treeAvailable: boolean }): PreviewModeSegment[] {
  switch (kind) {
    case "markdown":
      return [
        { mode: "split", label: "Split", enabled: true },
        { mode: "source", label: "Source", enabled: true },
        { mode: "preview", label: "Preview", enabled: true },
      ];
    case "json":
      return [
        { mode: "tree", label: "Tree", enabled: options.treeAvailable },
        { mode: "text", label: "Text", enabled: true },
      ];
    case "svg":
      return [
        { mode: "preview", label: "Preview", enabled: true },
        { mode: "source", label: "Source", enabled: true },
      ];
    case "table":
      return [
        { mode: "table", label: "Table", enabled: true },
        { mode: "text", label: "Text", enabled: true },
      ];
    case "image":
    case "text":
      return [];
  }
}

/**
 * The mode a file opens in when the pane has not been told otherwise: the rendered view for every
 * kind that has one, since the rendered view is why these kinds are singled out. JSON is the one
 * exception, and only when its tree is unavailable.
 *
 * `undefined` means the kind has no mode control: an image stage or a plain source buffer.
 */
export function defaultPreviewMode(kind: PreviewKind, options: { treeAvailable: boolean }): PreviewMode | undefined {
  switch (kind) {
    case "markdown":
      return "split";
    case "json":
      return options.treeAvailable ? "tree" : "text";
    case "svg":
      return "preview";
    case "table":
      return "table";
    case "image":
    case "text":
      return undefined;
  }
}

/**
 * The mode to show for a file, given whatever mode the pane remembers for it. A remembered mode is
 * honored only while it is still a selectable segment of this file's control: editing a `.json`
 * file in Text until it no longer parses takes the Tree segment away, and the view has to leave the
 * tree rather than keep rendering a stale one. Everything else keeps the user's choice.
 */
export function resolvePreviewMode(
  kind: PreviewKind,
  remembered: PreviewMode | undefined,
  options: { treeAvailable: boolean },
): PreviewMode | undefined {
  const segments = previewModeSegments(kind, options);
  if (remembered !== undefined && segments.some((segment) => segment.mode === remembered && segment.enabled)) {
    return remembered;
  }
  return defaultPreviewMode(kind, options);
}

/**
 * Whether the pane shows its editable source buffer. A kind with no mode control decides this on
 * its own: a plain file is nothing but its source, and an image has no source to show at all.
 */
export function modeShowsSource(kind: PreviewKind, mode: PreviewMode | undefined): boolean {
  if (kind === "image") return false;
  if (mode === undefined) return true;
  return mode === "split" || mode === "source" || mode === "text";
}

/** Whether the pane shows a rendered surface, beside the source in Split or instead of it. */
export function modeShowsPreview(kind: PreviewKind, mode: PreviewMode | undefined): boolean {
  if (kind === "image") return true;
  if (mode === undefined) return false;
  return mode === "split" || mode === "preview" || mode === "tree" || mode === "table";
}
