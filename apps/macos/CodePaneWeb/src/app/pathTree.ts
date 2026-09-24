import { WorkspaceSubmodule } from "../bridge/types";

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
  /** Full object id this directory's `HEAD` sits at, present only when the directory is a git
   *  submodule checkout (`WorkspaceFileListResult.submodules`). The renderer shows its first 7
   *  characters as a commit chip on this directory's row. */
  readonly submoduleCommit?: string;
}

export type PathTreeNode = PathTreeFileNode | PathTreeDirNode;

interface MutableDirNode {
  readonly kind: "dir";
  readonly name: string;
  readonly path: string;
  readonly children: (MutableDirNode | PathTreeFileNode)[];
  readonly subdirs: Map<string, MutableDirNode>;
  readonly submoduleCommit?: string;
}

function makeDir(name: string, path: string, submoduleCommit: string | undefined): MutableDirNode {
  return { kind: "dir", name, path, children: [], subdirs: new Map(), submoduleCommit };
}

/**
 * Builds a directory tree from a flat list of paths, sibling order matching `paths`' own order
 * (each directory's children appear in the order their first member was encountered) — mirrors
 * `fileTree.ts`'s `buildFileTree` exactly, including single-child directory chain compaction, just
 * over plain path strings instead of `DiffFileEntry`.
 *
 * `submodules` marks the directories that are git submodule checkouts, which the renderer chips
 * with the commit they sit at. As in `buildFileTree`, a submodule directory is a compaction
 * boundary in both directions, so that chip always has a row of its own to sit on and never one
 * whose label spans a repository boundary.
 *
 * A submodule's own directory is seeded even when no path in the listing sits inside it: an empty
 * checkout, or one holding only files the lister leaves out, is still checked out and still has a
 * commit worth showing. `emptyDirectories` (`WorkspaceFileListResult.emptyDirectories`) is seeded
 * for the same reason: a directory holding no file has no path of its own in `paths` to create it,
 * so without this seeding a just-created (or otherwise empty) folder would have no row at all.
 *
 * Both seeded kinds are merged INTO the `paths` walk rather than appended after it, each one placed
 * at the point where its own path sorts against the remaining paths (`workspaceFileList` returns all
 * three lists sorted ascending). Appending instead would hang every seeded directory off the end of
 * its parent's children, so a just-created `apps/empty` would render below `apps/main.ts` rather
 * than above it. The merge keeps `paths`' own order untouched: a directory created by a path still
 * appears where its first member put it, and a seeded directory simply takes the place among its
 * siblings its sorted position implies.
 */
export function buildPathTree(
  paths: readonly string[],
  submodules: readonly WorkspaceSubmodule[],
  emptyDirectories: readonly string[],
): PathTreeNode[] {
  const commitByPath = new Map(submodules.map((submodule) => [submodule.path, submodule.commit]));
  const root = makeDir("", "", undefined);
  /** Walks `segments`, creating each directory that does not exist yet, and returns the deepest. */
  const descend = (segments: readonly string[]): MutableDirNode => {
    let cursor = root;
    let cursorPath = "";
    for (const segment of segments) {
      cursorPath = cursorPath ? `${cursorPath}/${segment}` : segment;
      let child = cursor.subdirs.get(segment);
      if (!child) {
        child = makeDir(segment, cursorPath, commitByPath.get(cursorPath));
        cursor.subdirs.set(segment, child);
        cursor.children.push(child);
      }
      cursor = child;
    }
    return cursor;
  };
  // The two seeded kinds as one ascending list; both are short (a workspace's checkouts, and the
  // folders holding no listed file), so sorting them costs nothing next to the paths walk below,
  // which is never re-sorted.
  const seededDirs = [...submodules.map((submodule) => submodule.path), ...emptyDirectories].sort();
  let seedIndex = 0;
  /** Creates every seeded directory that sorts before `nextPath` (all of them when it is undefined,
   *  which is the tail past the last path). */
  const seedDirsBefore = (nextPath: string | undefined): void => {
    while (seedIndex < seededDirs.length && (nextPath === undefined || seededDirs[seedIndex]! < nextPath)) {
      descend(seededDirs[seedIndex]!.split("/"));
      seedIndex += 1;
    }
  };
  for (const path of paths) {
    seedDirsBefore(path);
    const segments = path.split("/");
    const baseName = segments.at(-1) ?? path;
    descend(segments.slice(0, -1)).children.push({ kind: "file", name: baseName, path });
  }
  seedDirsBefore(undefined);
  return root.children.map((child) => (child.kind === "dir" ? compactDir(child) : child));
}

function compactDir(dir: MutableDirNode): PathTreeDirNode {
  let label = dir.name;
  let end = dir;
  while (end.submoduleCommit === undefined && end.children.length === 1 && end.children[0]!.kind === "dir") {
    const next = end.children[0] as MutableDirNode;
    if (next.submoduleCommit !== undefined) break;
    end = next;
    label = `${label}/${end.name}`;
  }
  const children = end.children.map((child) => (child.kind === "dir" ? compactDir(child) : child));
  return {
    kind: "dir",
    label,
    path: end.path,
    children,
    ...(end.submoduleCommit !== undefined ? { submoduleCommit: end.submoduleCommit } : {}),
  };
}
