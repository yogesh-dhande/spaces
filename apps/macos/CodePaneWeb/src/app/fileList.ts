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
 * file under it shows only its own basename. Collapse state is per-render,
 * local to the DOM this call builds (see the per-directory closures below) —
 * it deliberately does not survive a later `renderFileList` call, since the
 * product spec for this view doesn't require it to.
 */

const STATUS_LABEL: Record<FileChangeStatus, string> = {
  added: "A",
  modified: "M",
  deleted: "D",
  renamed: "R",
  untracked: "U",
};

export interface FileListCallbacks {
  onSelect(path: string): void;
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
): void {
  container.replaceChildren();

  if (files.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "No changes";
    container.appendChild(empty);
    return;
  }

  for (const node of buildFileTree(files)) {
    container.appendChild(renderNode(node, 0, selectedPath, callbacks));
  }
}

function renderNode(
  node: FileTreeNode,
  depth: number,
  selectedPath: string | undefined,
  callbacks: FileListCallbacks,
): HTMLElement {
  return node.kind === "dir"
    ? renderDirNode(node, depth, selectedPath, callbacks)
    : renderFileNode(node, depth, selectedPath, callbacks);
}

function renderDirNode(
  node: FileTreeDirNode,
  depth: number,
  selectedPath: string | undefined,
  callbacks: FileListCallbacks,
): HTMLElement {
  const group = document.createElement("div");
  group.className = "dir-group";

  const dirrow = document.createElement("div");
  dirrow.className = "dirrow";
  dirrow.style.setProperty("--depth", String(depth));
  // The rows are divs for layout reasons, so button semantics + a tab stop + Enter/Space are added
  // by hand — without them the disclosure is pointer-only for keyboard and VoiceOver users.
  dirrow.setAttribute("role", "button");
  dirrow.tabIndex = 0;
  dirrow.setAttribute("aria-expanded", "true");

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
  for (const child of node.children) {
    childrenEl.appendChild(renderNode(child, depth + 1, selectedPath, callbacks));
  }

  let collapsed = false;
  const toggle = (): void => {
    collapsed = !collapsed;
    childrenEl.style.display = collapsed ? "none" : "";
    tri.textContent = collapsed ? "▸" : "▾";
    dirrow.setAttribute("aria-expanded", String(!collapsed));
  };
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
): HTMLElement {
  const file = node.file;
  const row = document.createElement("div");
  row.className = "row" + (file.path === selectedPath ? " on" : "");
  row.style.setProperty("--depth", String(depth));
  row.dataset.path = file.path;
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

  if (!file.isBinary && !file.truncated) {
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

  return row;
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
