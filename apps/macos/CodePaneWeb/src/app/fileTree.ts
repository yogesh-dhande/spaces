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
  /** Present when this directory is a git submodule checkout whose pointer moved: the gitlink
   *  entry itself, which the renderer shows as a commit chip on this directory's own row instead
   *  of as a separate leaf row. The submodule's changed files are this node's children. */
  readonly submodule?: DiffFileEntry;
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
  /** Plain directories by segment name. A submodule pointer at the same name is NOT here: it is a
   *  node of its own (see `submoduleSubdirs`), so a superproject file and a submodule's file that
   *  happen to share a path prefix never end up in the same folder. */
  readonly subdirs: Map<string, MutableDirNode>;
  /** Submodule pointer nodes by segment name, kept apart from `subdirs` for the same reason. Both
   *  maps push into the one `children` array, so sibling order still follows the file list. */
  readonly submoduleSubdirs: Map<string, MutableDirNode>;
  submodule?: DiffFileEntry;
}

function makeDir(name: string, path: string): MutableDirNode {
  return { kind: "dir", name, path, children: [], subdirs: new Map(), submoduleSubdirs: new Map() };
}

/** True for a git submodule (gitlink) pointer entry. The manifest's `isSubmodule` flag is checked
 *  alongside `submodule` so a pointer is placed as a directory node from the manifest alone, before
 *  its metadata-only chunk lands; otherwise the tree would reshape mid-stream. */
function isSubmodulePointer(file: DiffFileEntry): boolean {
  return file.isSubmodule === true || file.submodule !== undefined;
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
 *
 * A submodule (gitlink) pointer entry becomes the directory node for its own path rather than a
 * leaf row, and a submodule checked out inside another nests the same way. Which entries go inside
 * it is decided by `DiffFileEntry.submodulePath`, the owner the daemon names, NOT by path prefix:
 * the two disagree whenever a submodule is replaced by ordinary files at the same path (a removed
 * pointer `A` alongside a superproject `A/foo`), and placing `A/foo` inside the pointer would put
 * another repository's file in it and make a pointer with no checkout behind it look expandable.
 * An entry with no `submodulePath` belongs to the workspace's own repository; one naming an owner
 * this file list does not contain is treated the same way, so no entry is ever dropped.
 *
 * A pointer node and a plain directory node can therefore both exist for one path, and they are
 * siblings: the pointer holds what it owns (usually nothing, since a path git reports as both a
 * gitlink and a tree is a type change, which leaves the pointer no base to compare against), and
 * the plain folder holds the rest. `fileList.ts` keys the two rows apart by giving a pointer row a
 * change-shaped element id.
 */
export function buildFileTree(files: readonly DiffFileEntry[]): FileTreeNode[] {
  const root = makeDir("", "");
  /** Pointer nodes by their full path, so an entry naming one as its owner is placed into it
   *  directly. The daemon orders a submodule's entries after its pointer row, so the owner is
   *  always already here by the time its entries arrive. */
  const pointerNodes = new Map<string, MutableDirNode>();

  for (const file of files) {
    // The container this entry goes in, and the part of its path that is relative to that
    // container: the workspace's own tree for an unowned entry, otherwise its owner's pointer node.
    const container = (file.submodulePath !== undefined ? pointerNodes.get(file.submodulePath) : undefined) ?? root;
    const relative = container.path === "" ? file.path : file.path.slice(container.path.length + 1);
    const segments = relative.split("/");
    const baseName = segments.at(-1) ?? relative; // split() on any string yields at least one element

    let cursor = container;
    let cursorPath = container.path;
    // Every segment but the last is an ordinary directory inside the container, for a pointer entry
    // and an ordinary file alike: the last segment is what the entry itself becomes.
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

    if (!isSubmodulePointer(file)) {
      cursor.children.push({ kind: "file", name: baseName, file });
      continue;
    }
    let pointerNode = cursor.submoduleSubdirs.get(baseName);
    if (!pointerNode) {
      pointerNode = makeDir(baseName, file.path);
      cursor.submoduleSubdirs.set(baseName, pointerNode);
      cursor.children.push(pointerNode);
    }
    pointerNode.submodule = file;
    pointerNodes.set(file.path, pointerNode);
  }
  return root.children.map((child) => (child.kind === "dir" ? compactDir(child) : child));
}

/** Walks down a chain of single-child directories, folding each into the returned row's `label`,
 *  then recursively compacts whatever directory children remain once the chain ends (a fork, a
 *  directory holding a file, or a leaf directory with multiple files).
 *
 *  A submodule directory is a hard boundary in both directions: folding it into its parent would
 *  bury the repository boundary in a compacted label with nowhere to hang its commit chip, and
 *  folding a plain child into a submodule row would make that row claim a path the pointer does not
 *  name. So the chain stops before entering a submodule and never starts from one. */
function compactDir(dir: MutableDirNode): FileTreeDirNode {
  let label = dir.name;
  let end = dir;
  while (end.submodule === undefined && end.children.length === 1 && end.children[0]!.kind === "dir") {
    const next = end.children[0] as MutableDirNode;
    if (next.submodule !== undefined) break;
    end = next;
    label = `${label}/${end.name}`;
  }
  const children = end.children.map((child) => (child.kind === "dir" ? compactDir(child) : child));
  return { kind: "dir", label, path: end.path, children, ...(end.submodule !== undefined ? { submodule: end.submodule } : {}) };
}
