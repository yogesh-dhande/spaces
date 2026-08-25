import { buildPathTree, PathTreeDirNode, PathTreeFileNode, PathTreeNode } from "./pathTree";

export interface FilesTreeCallbacks {
  onSelect(path: string): void;
}

/** Returned by `renderFilesTree`; the only way callers touch the tree after the initial paint. */
export interface FilesTreeHandle {
  /** Moves the highlighted row to `path` (expanding and materializing its ancestor chain as
   *  needed) and scrolls it into view, or just clears the previous highlight if `path` is
   *  `undefined` or isn't present in this tree. Never rebuilds already-materialized DOM — see the
   *  module doc comment below. */
  setSelected(path: string | undefined): void;
}

/**
 * Renders Editor mode's "Files" list (the full workspace listing, see `editorSidebar.ts`) into
 * `container`. Deliberately the same collapse/indent/row DOM idiom as `fileList.ts`'s Changes
 * list — `.dir-group`/`.dirrow`/`.tri`/`.dirlabel`/`.row`/`.fn`, driven by the same `--depth` CSS
 * custom property — so both lists share one set of CSS rules in `app.css` with no new selectors,
 * just with no `.status` letter or `.st` +/- stat column: every file in the full listing is
 * unchanged by definition (a changed file also appears in the Changes list, which is what carries
 * that information).
 *
 * Unlike `fileList.ts`'s Changes tree — small (bounded by how many files are actually dirty) and
 * fully expanded on every render — this listing is capped at 50,000 paths. Materializing every
 * row's DOM and listeners up front, or rebuilding the whole tree on every file open (as this used
 * to do), blocks the WKWebView at that size. So directories render collapsed by default, a
 * directory's children are built into its `.dir-children` element only the first time it is
 * expanded (a collapsed directory that's never opened costs nothing beyond its own `.dirrow`), and
 * `FilesTreeHandle.setSelected` moves the highlight in place — expanding and materializing just the
 * selected path's own ancestor chain — instead of re-rendering the tree per selection change. The
 * one eager exception is the initial paint: every ancestor of the given `selectedPath` starts
 * expanded and materialized, so the selected row is already visible and highlighted on first paint
 * rather than requiring a manual expand.
 */
export function renderFilesTree(
  container: HTMLElement,
  paths: readonly string[],
  selectedPath: string | undefined,
  callbacks: FilesTreeCallbacks,
): FilesTreeHandle {
  container.replaceChildren();

  const registry: Registry = { dirs: new Map(), files: new Map() };

  if (paths.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "No files";
    container.appendChild(empty);
    return { setSelected: () => {} };
  }

  const tree = buildPathTree(paths);
  const initialChain = new Set(selectedPath !== undefined ? (collectAncestorDirs(tree, selectedPath) ?? []) : []);

  for (const node of tree) {
    container.appendChild(renderNode(node, 0, initialChain, selectedPath, callbacks, registry));
  }

  let selectedRow = selectedPath !== undefined ? registry.files.get(selectedPath) : undefined;

  return {
    setSelected(path: string | undefined): void {
      selectedRow?.classList.remove("on");
      selectedRow = undefined;
      if (path === undefined) return;

      const ancestorChain = collectAncestorDirs(tree, path);
      if (ancestorChain === undefined) return; // not present in this tree

      for (const dirPath of ancestorChain) registry.dirs.get(dirPath)?.ensureExpanded();

      const row = registry.files.get(path);
      if (!row) return;
      row.classList.add("on");
      selectedRow = row;
      row.scrollIntoView({ block: "nearest" });
    },
  };
}

interface DirControl {
  /** Expands (materializing if needed) this directory if it is currently collapsed; a no-op
   *  otherwise. Never collapses — only the dirrow's own click/keydown toggle does that. */
  ensureExpanded(): void;
}

/** Populated as rows are materialized, so `setSelected` can reach a directory or file row directly
 *  by its full path instead of walking the DOM. Only ever grows — a row, once materialized, is
 *  never removed from the registry (or the DOM) for the lifetime of this render. */
interface Registry {
  dirs: Map<string, DirControl>;
  files: Map<string, HTMLElement>;
}

/**
 * Returns the full path's ancestor directory rows, root-to-leaf, or `undefined` if `path` isn't a
 * file in this tree. A directory's row `path` is its compacted chain's end (see `pathTree.ts`'s
 * `compactDir`), so this returns exactly the rows `setSelected` needs to expand — no intermediate
 * segment that got folded into a compacted label has a row of its own to expand.
 */
function collectAncestorDirs(nodes: readonly PathTreeNode[], path: string): string[] | undefined {
  for (const node of nodes) {
    if (node.kind === "file") {
      if (node.path === path) return [];
    } else if (path.startsWith(node.path + "/")) {
      const rest = collectAncestorDirs(node.children, path);
      if (rest !== undefined) return [node.path, ...rest];
    }
  }
  return undefined;
}

function renderNode(
  node: PathTreeNode,
  depth: number,
  initialChain: ReadonlySet<string>,
  selectedPath: string | undefined,
  callbacks: FilesTreeCallbacks,
  registry: Registry,
): HTMLElement {
  return node.kind === "dir"
    ? renderDirNode(node, depth, initialChain, selectedPath, callbacks, registry)
    : renderFileNode(node, depth, selectedPath, callbacks, registry);
}

// Identical to fileList.ts's renderDirNode: directory rows carry no per-file information, so the
// two lists' directory chrome is exactly the same code, just duplicated rather than shared across
// a module boundary for two small, independently-testable renderers (see pathTree.ts's doc
// comment for the same tradeoff on the tree-building side).
function renderDirNode(
  node: PathTreeDirNode,
  depth: number,
  initialChain: ReadonlySet<string>,
  selectedPath: string | undefined,
  callbacks: FilesTreeCallbacks,
  registry: Registry,
): HTMLElement {
  const group = document.createElement("div");
  group.className = "dir-group";

  const dirrow = document.createElement("div");
  dirrow.className = "dirrow";
  dirrow.style.setProperty("--depth", String(depth));
  dirrow.setAttribute("role", "button");
  dirrow.tabIndex = 0;

  const tri = document.createElement("span");
  tri.className = "tri";
  dirrow.appendChild(tri);

  const label = document.createElement("span");
  label.className = "dirlabel";
  label.textContent = node.label;
  label.title = node.label;
  dirrow.appendChild(label);

  const childrenEl = document.createElement("div");
  childrenEl.className = "dir-children";

  // Collapsed by default; the one exception is an ancestor of the initial selectedPath, which
  // starts expanded and materialized (see the module doc comment) so the selected row paints
  // visible and highlighted without requiring a manual expand.
  let expanded = initialChain.has(node.path);
  let materialized = false;

  const materialize = (): void => {
    if (materialized) return;
    materialized = true;
    for (const child of node.children) {
      childrenEl.appendChild(renderNode(child, depth + 1, initialChain, selectedPath, callbacks, registry));
    }
  };

  const applyExpandedState = (): void => {
    childrenEl.style.display = expanded ? "" : "none";
    tri.textContent = expanded ? "▾" : "▸";
    dirrow.setAttribute("aria-expanded", String(expanded));
  };

  const toggle = (): void => {
    materialize();
    expanded = !expanded;
    applyExpandedState();
  };

  if (expanded) materialize();
  applyExpandedState();

  dirrow.addEventListener("click", toggle);
  dirrow.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" && event.key !== " ") return;
    event.preventDefault();
    if (event.repeat) return;
    toggle();
  });

  registry.dirs.set(node.path, {
    ensureExpanded: () => {
      if (!expanded) toggle();
    },
  });

  group.appendChild(dirrow);
  group.appendChild(childrenEl);
  return group;
}

function renderFileNode(
  node: PathTreeFileNode,
  depth: number,
  selectedPath: string | undefined,
  callbacks: FilesTreeCallbacks,
  registry: Registry,
): HTMLElement {
  const row = document.createElement("div");
  row.className = "row" + (node.path === selectedPath ? " on" : "");
  row.style.setProperty("--depth", String(depth));
  row.dataset.path = node.path;
  row.setAttribute("role", "button");
  row.tabIndex = 0;
  row.addEventListener("click", () => callbacks.onSelect(node.path));
  row.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" && event.key !== " ") return;
    event.preventDefault();
    if (event.repeat) return;
    callbacks.onSelect(node.path);
  });

  const fn = document.createElement("span");
  fn.className = "fn";
  fn.textContent = node.name;
  fn.title = node.path;
  row.appendChild(fn);

  registry.files.set(node.path, row);
  return row;
}
