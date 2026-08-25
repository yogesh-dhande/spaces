import { DiffFileEntry } from "../bridge/types";

/** A file leaf in the file tree. Carries the original `DiffFileEntry` so a renderer keeps every
 *  per-file field (status, patch, etc.) with no second lookup back into the flat file list. */
export interface FileTreeFileNode {
  readonly kind: "file";
  /** Basename only — an ancestor `FileTreeDirNode` row already renders the directory portion. */
  readonly name: string;
  readonly file: DiffFileEntry;
}

/** A directory row, possibly representing a compacted chain of several single-child directories
 *  (see `buildFileTree`'s doc comment). */
export interface FileTreeDirNode {
  readonly kind: "dir";
  /** The row's display label: one path segment, or several joined with `/` when this row compacts
   *  a single-child chain (e.g. `"apps/macos/Sources"`). */
  readonly label: string;
  /** Full workspace-relative path of the directory this row ends at — the deepest directory in its
   *  compacted chain. Stable across re-renders of the same tree shape, unlike `label` (which two
   *  different diffs could coincidentally share). */
  readonly path: string;
  readonly children: readonly FileTreeNode[];
}

export type FileTreeNode = FileTreeFileNode | FileTreeDirNode;

/** Mutable construction node used only while walking `files`; folded into the immutable
 *  `FileTreeNode` shape by `compactDir` once every file has been placed. Kept distinct from
 *  `FileTreeDirNode` because construction needs `subdirs` (a name -> node lookup, so a second file
 *  under an already-seen directory extends it instead of creating a sibling) which the render-facing
 *  type has no use for. */
interface MutableDirNode {
  readonly kind: "dir";
  readonly name: string;
  readonly path: string;
  readonly children: (MutableDirNode | FileTreeFileNode)[];
  readonly subdirs: Map<string, MutableDirNode>;
}

function makeDir(name: string, path: string): MutableDirNode {
  return { kind: "dir", name, path, children: [], subdirs: new Map() };
}

/**
 * Builds a directory tree from a flat diff file list, for the file-list sidebar's tree presentation
 * (see docs mockup "G — Tree with compacted chains"). Sibling order mirrors `files`' own order: each
 * directory's children appear in the order their first member was encountered.
 *
 * Single-child directory *chains* compact into one row, the way editors' "compact folders" mode
 * works: a run of directories where each holds only the next (`apps` -> `macos` -> `Sources`, with
 * `Sources` the first to hold more than one entry) renders as a single row labeled
 * `"apps/macos/Sources"`. A directory is only ever folded into a further directory this way, never
 * into a sibling file — a folder holding exactly one file still gets its own row, since collapsing
 * that case would hide the file's directory context instead of merely shortening it.
 */
export function buildFileTree(files: readonly DiffFileEntry[]): FileTreeNode[] {
  const root = makeDir("", "");
  for (const file of files) {
    const segments = file.path.split("/");
    const baseName = segments.at(-1) ?? file.path; // split() on any string yields at least one element
    let cursor = root;
    let cursorPath = "";
    for (let i = 0; i < segments.length - 1; i++) {
      const segment = segments[i]!;
      cursorPath = cursorPath ? `${cursorPath}/${segment}` : segment;
      let child = cursor.subdirs.get(segment);
      if (!child) {
        child = makeDir(segment, cursorPath);
        cursor.subdirs.set(segment, child);
        cursor.children.push(child);
      }
      cursor = child;
    }
    cursor.children.push({ kind: "file", name: baseName, file });
  }
  return root.children.map((child) => (child.kind === "dir" ? compactDir(child) : child));
}

/** Walks down a chain of single-child directories, folding each into the returned row's `label`,
 *  then recursively compacts whatever directory children remain once the chain ends (a fork, a
 *  directory holding a file, or a leaf directory with multiple files). */
function compactDir(dir: MutableDirNode): FileTreeDirNode {
  let label = dir.name;
  let end = dir;
  while (end.children.length === 1 && end.children[0]!.kind === "dir") {
    end = end.children[0] as MutableDirNode;
    label = `${label}/${end.name}`;
  }
  const children = end.children.map((child) => (child.kind === "dir" ? compactDir(child) : child));
  return { kind: "dir", label, path: end.path, children };
}
