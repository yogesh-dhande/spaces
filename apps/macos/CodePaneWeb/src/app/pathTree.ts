/**
 * Directory tree builder for a flat list of plain workspace-relative paths — the Files tree half
 * of Editor mode's sidebar toggle (see `editorSidebar.ts`) and the same "compacted chains"
 * presentation `fileTree.ts` builds for the Changes list, but over `workspaceFileList`'s bare
 * `string[]` rather than `DiffFileEntry[]` (which carries no per-file status/patch here — every
 * file in the workspace listing is just a path). Kept as its own small module, parallel to
 * `fileTree.ts`, rather than a generic shared implementation: the two leaf shapes (a path vs. a
 * full `DiffFileEntry`) are different enough that a shared generic would need type-parameterizing
 * `buildFileTree` for a single caller, for little real gain over the two independent (and each
 * simpler) implementations.
 */

export interface PathTreeFileNode {
  readonly kind: "file";
  /** Basename only — an ancestor `PathTreeDirNode` row already renders the directory portion. */
  readonly name: string;
  /** Full workspace-relative path. */
  readonly path: string;
}

export interface PathTreeDirNode {
  readonly kind: "dir";
  /** The row's display label: one path segment, or several joined with `/` when this row compacts
   *  a single-child chain (e.g. `"apps/macos/Sources"`) — see `buildPathTree`'s doc comment. */
  readonly label: string;
  /** Full workspace-relative path of the directory this row ends at. */
  readonly path: string;
  readonly children: readonly PathTreeNode[];
}

export type PathTreeNode = PathTreeFileNode | PathTreeDirNode;

interface MutableDirNode {
  readonly kind: "dir";
  readonly name: string;
  readonly path: string;
  readonly children: (MutableDirNode | PathTreeFileNode)[];
  readonly subdirs: Map<string, MutableDirNode>;
}

function makeDir(name: string, path: string): MutableDirNode {
  return { kind: "dir", name, path, children: [], subdirs: new Map() };
}

/**
 * Builds a directory tree from a flat list of paths, sibling order matching `paths`' own order
 * (each directory's children appear in the order their first member was encountered) — mirrors
 * `fileTree.ts`'s `buildFileTree` exactly, including single-child directory chain compaction, just
 * over plain path strings instead of `DiffFileEntry`.
 */
export function buildPathTree(paths: readonly string[]): PathTreeNode[] {
  const root = makeDir("", "");
  for (const path of paths) {
    const segments = path.split("/");
    const baseName = segments.at(-1) ?? path;
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
    cursor.children.push({ kind: "file", name: baseName, path });
  }
  return root.children.map((child) => (child.kind === "dir" ? compactDir(child) : child));
}

function compactDir(dir: MutableDirNode): PathTreeDirNode {
  let label = dir.name;
  let end = dir;
  while (end.children.length === 1 && end.children[0]!.kind === "dir") {
    end = end.children[0] as MutableDirNode;
    label = `${label}/${end.name}`;
  }
  const children = end.children.map((child) => (child.kind === "dir" ? compactDir(child) : child));
  return { kind: "dir", label, path: end.path, children };
}
