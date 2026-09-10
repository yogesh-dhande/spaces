import { DiffFileEntry, FileChangeStatus } from "../bridge/types";
import { buildFileTree, FileTreeDirNode, FileTreeFileNode, FileTreeNode } from "./fileTree";
import { submoduleLabel } from "./submoduleLabel";

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
 * file under it shows only its own basename. A git submodule is one of those
 * directory rows, carrying a chip that names the commit its pointer moved to,
 * with the submodule's own changed files nested under it. The caller supplies the current
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
  /** Materialized submodule pointer rows, keyed by pointer path. Separate from `rows` because a
   *  pointer is a DIRECTORY row: its update replaces a commit chip, not a status glyph and a stat
   *  column, so the two kinds of row can never be mixed up by a lookup. */
  submoduleRows: Map<string, HTMLElement>;
  paths: Set<string>;
  latestFiles: Map<string, DiffFileEntry>;
  /** Held so a chip rebuilt by `updateFileListRow` re-binds the same selection callback the
   *  original render gave it. */
  callbacks: FileListCallbacks;
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
    submoduleRows: new Map<string, HTMLElement>(),
    paths: new Set(files.map((file) => file.path)),
    latestFiles: new Map(files.map((file) => [file.path, file])),
    callbacks,
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
  const submoduleRow = state.submoduleRows.get(file.path);
  if (submoduleRow) {
    // A pointer's directory row shows nothing that patch progress can change except its chip, which
    // reads "submodule" from the manifest flag alone and becomes the pointer's commit once the
    // metadata-only chunk lands. The chip is rebuilt whole rather than retitled in place so its
    // text, tooltip, and not-checked-out styling can never disagree with each other, and replacing
    // it (instead of appending) is what keeps one chip on a row updated once per patch-state step.
    submoduleRow.querySelector(":scope > .submodule-badge")?.remove();
    submoduleRow.appendChild(renderSubmoduleChip(file, state.callbacks));
    return "updated";
  }
  const row = state.rows.get(file.path);
  if (!row) return "hidden";
  const status = row.querySelector<HTMLElement>(":scope > .status");
  if (status) {
    status.className = `status ${file.status}`;
    status.textContent = STATUS_LABEL[file.status];
  }
  // Every span appendFileProgress can produce is cleared first: a row is updated once per
  // patch-state step (queued, streaming, ready) and would otherwise stack one per step.
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
    // A submodule pointer's path names a DIRECTORY row, so a selection restored onto one resolves
    // to that row's ancestor chain instead of to nothing. The submodule's own folder is not part of
    // that chain: the pointer is the folder row itself, visible whether it is open or closed.
    if (node.path === path) return [];
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

/**
 * A directory row. A git submodule is one of these: its pointer entry becomes the row for its own
 * path, carrying a commit chip at the right edge, with the submodule's changed files (and any
 * submodule checked out inside it) as this row's children (see `buildFileTree`). Clicking the row
 * discloses those files; clicking the chip selects the pointer entry itself, which is a separate
 * item in the diff.
 *
 * A pointer with nothing nested under it (never checked out, or checked out with no changes of its
 * own) has nothing to disclose, so it renders without a triangle and without the toggle: its chip
 * is then the row's only control, rather than a tab stop that does nothing when activated. Whether
 * a pointer has children is fixed by the manifest, so this never changes under a row that is
 * already on screen.
 */
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
  // Only a submodule row can be selected: it stands in for the pointer entry a file row used to
  // carry, so it takes the same selected highlight when the chip's selection lands on it.
  dirrow.className = node.submodule !== undefined && node.path === selectedPath ? "dirrow on" : "dirrow";
  // A pointer row is identified as the change entry it is, not as a plain directory. That is also
  // what keeps the two rows apart when a path carries both (a submodule replaced by ordinary files,
  // see `buildFileTree`): sharing one element id would leave the pointer and the plain folder
  // indistinguishable to anything addressing a row by id.
  dirrow.id =
    node.submodule !== undefined
      ? `code-pane-change-${encodeURIComponent(node.path)}`
      : `code-pane-diff-directory-${encodeURIComponent(node.path)}`;
  dirrow.style.setProperty("--depth", String(depth));

  const childrenEl = document.createElement("div");
  childrenEl.className = "dir-children";

  if (node.children.length > 0) {
    // The rows are divs for layout reasons, so button semantics + a tab stop + Enter/Space are added
    // by hand: without them the disclosure is pointer-only for keyboard and VoiceOver users.
    dirrow.setAttribute("role", "button");
    dirrow.tabIndex = 0;

    const tri = document.createElement("span");
    tri.className = "tri";
    tri.textContent = "▾";
    dirrow.appendChild(tri);

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
  }

  const label = document.createElement("span");
  label.className = "dirlabel";
  label.textContent = node.label;
  label.title = node.label;
  dirrow.appendChild(label);

  if (node.submodule !== undefined) {
    // The chip renders from the latest entry for this path, not the one the tree was built from,
    // so a pointer whose metadata already landed while its parent folder was closed shows its
    // commit the moment the folder opens (the same reason `renderFileNode` reads `latestFiles`).
    const pointer = renderState.latestFiles.get(node.submodule.path) ?? node.submodule;
    dirrow.dataset.path = pointer.path;
    dirrow.appendChild(renderSubmoduleChip(pointer, callbacks));
    renderState.submoduleRows.set(pointer.path, dirrow);
  }

  group.appendChild(dirrow);
  group.appendChild(childrenEl);
  return group;
}

/** The chip on a submodule directory row: the pointer's commit, the whole pointer label as its
 *  tooltip, and a click that selects the pointer entry rather than disclosing the folder. */
function renderSubmoduleChip(file: DiffFileEntry, callbacks: FileListCallbacks): HTMLElement {
  const chip = document.createElement("button");
  chip.type = "button";
  chip.className = file.submodule?.checkedOut === false ? "submodule-badge not-checked-out" : "submodule-badge";
  chip.textContent = submoduleChipText(file);
  chip.setAttribute("aria-label", `Submodule pointer for ${file.path}`);
  if (file.submodule !== undefined) chip.title = submoduleLabel(file.submodule);
  chip.addEventListener("click", (event) => {
    // The row around this chip is the folder's disclosure toggle, so without this the one click
    // would both select the pointer and collapse the files the selection is meant to sit above.
    event.stopPropagation();
    callbacks.onSelect(file.path);
  });
  chip.addEventListener("keydown", (event) => {
    // Same reason as the click handler, one step earlier: the folder row's own Enter/Space handler
    // toggles and calls preventDefault, which would both close the folder and suppress the click
    // this button synthesizes from the key press, so a keyboard user could never select the
    // pointer. Stopping the key here leaves the button's native activation to do its own work.
    if (event.key !== "Enter" && event.key !== " ") return;
    event.stopPropagation();
  });
  return chip;
}

/** The chip's text: the 7-character commit the pointer names (its new side, or its old side for a
 *  submodule the comparison removed), or the fixed word "submodule" while only the manifest's
 *  `isSubmodule` flag is known and the metadata-only chunk carrying the commits has not landed. */
function submoduleChipText(file: DiffFileEntry): string {
  const commit = file.submodule?.newCommit ?? file.submodule?.oldCommit;
  return commit === undefined ? "submodule" : commit.slice(0, 7);
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

/** Adornment for a FILE row only. A submodule pointer never reaches here: it is a directory row
 *  carrying a commit chip instead of a transfer spinner or a +/- stat, since a gitlink has no patch
 *  to transfer or count lines from (see `renderDirNode`). */
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
