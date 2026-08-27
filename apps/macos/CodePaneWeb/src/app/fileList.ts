import { DiffFileEntry, FileChangeStatus } from "../bridge/types";
import { buildFileTree, FileTreeDirNode, FileTreeFileNode, FileTreeNode } from "./fileTree";

/**
 * Diff-mode file list sidebar. Not part of the picked Variant A mockup's own
 * markup (that variant renders files inline with no picker chrome), but
 * required by Phase 3's functional scope: a way to see every changed file at
 * a glance and jump to one. Borrows the mockup's Variant B `.rail` metrics
 * and tokens since that is the mockup's only other file-list treatment.
 *
 * Renders `files` as a directory tree (docs mockup "G — Tree with compacted
 * chains" — see `buildFileTree`), rather than one flat row per file: a
 * directory row shows its (possibly chain-compacted) path once, and every
 * file under it shows only its own basename. The caller supplies the current
 * workspace's expanded paths and receives expansion changes, so rebuilding
 * the DOM preserves that workspace's tree state without retaining UI state in
 * this renderer.
 */

const STATUS_LABEL: Record<FileChangeStatus, string> = {
  added: "A",
  modified: "M",
  deleted: "D",
  renamed: "R",
  untracked: "U",
};

/** Each manifest render records its materialized rows and complete path set. Patch progress does
 * not change the tree shape, so a streamed update can address one row without walking the sidebar
 * DOM; a valid but collapsed path can be updated in the backing manifest without rebuilding it. */
interface FileListRenderState {
  rows: Map<string, HTMLElement>;
  paths: Set<string>;
  latestFiles: Map<string, DiffFileEntry>;
}

const stateByContainer = new WeakMap<HTMLElement, FileListRenderState>();

export type FileListRowUpdateResult = "updated" | "hidden" | "stale";

export interface FileListCallbacks {
  onSelect(path: string): void;
  onExpandedPathsChange?(paths: readonly string[]): void;
}

/**
 * Renders the sidebar into `container`. A file row's `data-path` always
 * carries its full workspace-relative path (its `title` tooltip too, for
 * when the basename itself truncates) even though its visible text is only
 * the basename — this is also what lets `container.querySelector` find one
 * row by path in tests, independent of how deep the tree nests it.
 */
export function renderFileList(
  container: HTMLElement,
  files: readonly DiffFileEntry[],
  selectedPath: string | undefined,
  callbacks: FileListCallbacks,
  initiallyExpandedPaths?: readonly string[],
): void {
  container.replaceChildren();
  const rowsByPath = new Map<string, HTMLElement>();
  const renderState: FileListRenderState = {
    rows: rowsByPath,
    paths: new Set(files.map((file) => file.path)),
    latestFiles: new Map(files.map((file) => [file.path, file])),
  };
  stateByContainer.set(container, renderState);

  if (files.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "No changes";
    container.appendChild(empty);
    return;
  }

  const tree = buildFileTree(files);
  const expandedPaths = new Set(initiallyExpandedPaths);
  // Callers that do not have a recovery snapshot retain the original compact, fully-open review
  // list. A supplied empty array is meaningful persisted state: every directory is collapsed.
  if (initiallyExpandedPaths === undefined) addDirectoryPaths(tree, expandedPaths);
  // Keep a restored selection visible even when its directory was collapsed in the saved tree.
  // This mirrors the full Files tree: selection is a navigation target, so revealing its ancestor
  // chain takes precedence over the previous disclosure state for this initial render.
  for (const path of selectedPath !== undefined ? collectAncestorDirs(tree, selectedPath) ?? [] : []) {
    expandedPaths.add(path);
  }
  for (const node of tree) {
    container.appendChild(renderNode(node, 0, selectedPath, callbacks, expandedPaths, renderState));
  }
}

/** Updates just one already-materialized file row while a patch progresses. The manifest fixes the
 * tree's order and shape, so patch-state/stat changes do not need to rebuild every directory row,
 * replace click handlers, or disturb expanded folders. Returns false only if a newer manifest has
 * already replaced the tree and the caller should render that authoritative list instead. */
export function updateFileListRow(container: HTMLElement, file: DiffFileEntry): FileListRowUpdateResult {
  const state = stateByContainer.get(container);
  if (!state?.paths.has(file.path)) return "stale";
  state.latestFiles.set(file.path, file);
  const row = state.rows.get(file.path);
  if (!row) return "hidden";
  const status = row.querySelector<HTMLElement>(":scope > .status");
  if (status) {
    status.className = `status ${file.status}`;
    status.textContent = STATUS_LABEL[file.status];
  }
  for (const child of [...row.children]) {
    if (child.classList.contains("transfer") || child.classList.contains("st")) child.remove();
  }
  appendFileProgress(row, file);
  return "updated";
}

function addDirectoryPaths(nodes: readonly FileTreeNode[], paths: Set<string>): void {
  for (const node of nodes) {
    if (node.kind !== "dir") continue;
    paths.add(node.path);
    addDirectoryPaths(node.children, paths);
  }
}

/** Returns the directory rows from root to the row containing `path`, or undefined when the path
 * is not in this manifest. Compacted directory chains have one row at their deepest path, so the
 * returned paths are exactly the rows that need expanding. */
function collectAncestorDirs(nodes: readonly FileTreeNode[], path: string): string[] | undefined {
  for (const node of nodes) {
    if (node.kind === "file") {
      if (node.file.path === path) return [];
      continue;
    }
    if (!path.startsWith(`${node.path}/`)) continue;
    const rest = collectAncestorDirs(node.children, path);
    if (rest !== undefined) return [node.path, ...rest];
  }
  return undefined;
}

function renderNode(
  node: FileTreeNode,
  depth: number,
  selectedPath: string | undefined,
  callbacks: FileListCallbacks,
  expandedPaths: Set<string>,
  renderState: FileListRenderState,
): HTMLElement {
  return node.kind === "dir"
    ? renderDirNode(node, depth, selectedPath, callbacks, expandedPaths, renderState)
    : renderFileNode(node, depth, selectedPath, callbacks, renderState);
}

function renderDirNode(
  node: FileTreeDirNode,
  depth: number,
  selectedPath: string | undefined,
  callbacks: FileListCallbacks,
  expandedPaths: Set<string>,
  renderState: FileListRenderState,
): HTMLElement {
  const group = document.createElement("div");
  group.className = "dir-group";

  const dirrow = document.createElement("div");
  dirrow.className = "dirrow";
  dirrow.id = `code-pane-diff-directory-${encodeURIComponent(node.path)}`;
  dirrow.style.setProperty("--depth", String(depth));
  // The rows are divs for layout reasons, so button semantics + a tab stop + Enter/Space are added
  // by hand — without them the disclosure is pointer-only for keyboard and VoiceOver users.
  dirrow.setAttribute("role", "button");
  dirrow.tabIndex = 0;

  const tri = document.createElement("span");
  tri.className = "tri";
  tri.textContent = "▾";
  dirrow.appendChild(tri);

  const label = document.createElement("span");
  label.className = "dirlabel";
  label.textContent = node.label;
  label.title = node.label;
  dirrow.appendChild(label);

  const childrenEl = document.createElement("div");
  childrenEl.className = "dir-children";
  let expanded = expandedPaths.has(node.path);
  let materialized = false;

  const materialize = (): void => {
    if (materialized) return;
    materialized = true;
    for (const child of node.children) {
      childrenEl.appendChild(renderNode(child, depth + 1, selectedPath, callbacks, expandedPaths, renderState));
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
    if (expanded) expandedPaths.add(node.path);
    else expandedPaths.delete(node.path);
    applyExpandedState();
    callbacks.onExpandedPathsChange?.([...expandedPaths]);
  };

  if (expanded) materialize();
  applyExpandedState();
  dirrow.addEventListener("click", toggle);
  dirrow.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" && event.key !== " ") return;
    event.preventDefault(); // Space would otherwise scroll the list
    if (event.repeat) return; // a held key would oscillate the disclosure
    toggle();
  });

  group.appendChild(dirrow);
  group.appendChild(childrenEl);
  return group;
}

function renderFileNode(
  node: FileTreeFileNode,
  depth: number,
  selectedPath: string | undefined,
  callbacks: FileListCallbacks,
  renderState: FileListRenderState,
): HTMLElement {
  const file = renderState.latestFiles.get(node.file.path) ?? node.file;
  const row = document.createElement("div");
  row.className = "row" + (file.path === selectedPath ? " on" : "");
  row.style.setProperty("--depth", String(depth));
  row.dataset.path = file.path;
  renderState.rows.set(file.path, row);
  row.id = `code-pane-change-${encodeURIComponent(file.path)}`;
  // Same hand-rolled button semantics as the directory rows above, so file selection is
  // keyboard-operable too.
  row.setAttribute("role", "button");
  row.tabIndex = 0;
  row.addEventListener("click", () => callbacks.onSelect(file.path));
  row.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" && event.key !== " ") return;
    event.preventDefault();
    if (event.repeat) return;
    callbacks.onSelect(file.path);
  });

  const status = document.createElement("span");
  status.className = `status ${file.status}`;
  status.textContent = STATUS_LABEL[file.status];
  row.appendChild(status);

  const fn = document.createElement("span");
  fn.className = "fn";
  fn.textContent = node.name;
  fn.title = file.path;
  row.appendChild(fn);

  appendFileProgress(row, file);

  return row;
}

function appendFileProgress(row: HTMLElement, file: DiffFileEntry): void {
  if (file.patchState !== undefined && file.patchState !== "ready") {
    const transfer = document.createElement("span");
    transfer.className = `transfer ${file.patchState}`;
    transfer.textContent = file.patchState === "streaming" ? "Loading…" : "Queued";
    row.appendChild(transfer);
  } else if (!file.isBinary && file.patch !== undefined) {
    const stat = document.createElement("span");
    stat.className = "st";
    const counts = countChanges(file);
    const p = document.createElement("span");
    p.className = "p";
    p.textContent = `+${counts.additions}`;
    const m = document.createElement("span");
    m.className = "m";
    m.textContent = ` -${counts.deletions}`;
    stat.appendChild(p);
    stat.appendChild(m);
    row.appendChild(stat);
  }
}

/**
 * Additions/deletions for a file's stat display, counted from its patch's
 * `+`/`-` prefixed lines rather than a separate daemon-provided count (the
 * bridge contract does not carry one — see `DiffFileEntry`). Counting starts
 * only once a `@@` hunk header has been seen: the `+++ b/...`/`--- a/...`
 * file-header preamble lines always appear before the first hunk header, so
 * gating on `inHunk` excludes them without needing a `+++`/`---` special-case
 * that would otherwise also (incorrectly) skip a real hunk line whose content
 * happens to start with `++` or `--` (e.g. `++x` renders as `+++x`).
 */
function countChanges(file: DiffFileEntry): { additions: number; deletions: number } {
  if (!file.patch) return { additions: 0, deletions: 0 };
  let additions = 0;
  let deletions = 0;
  let inHunk = false;
  for (const line of file.patch.split("\n")) {
    if (line.startsWith("@@")) {
      inHunk = true;
      continue;
    }
    if (!inHunk) continue;
    if (line.startsWith("+")) additions++;
    else if (line.startsWith("-")) deletions++;
  }
  return { additions, deletions };
}
