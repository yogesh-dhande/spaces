import { DiffFileEntry, FileChangeStatus } from "../bridge/types";

/**
 * Diff-mode file list sidebar. Not part of the picked Variant A mockup's own
 * markup (that variant renders files inline with no picker chrome), but
 * required by Phase 3's functional scope: a way to see every changed file at
 * a glance and jump to one. Borrows the mockup's Variant B `.rail` metrics
 * and tokens since that is the mockup's only other file-list treatment.
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
 * Renders the sidebar into `container`. Row order matches `files` exactly
 * (the same order the diff view lays its `CodeView` items out in), so a
 * row's index doubles as its diff item's scroll target.
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

  for (const file of files) {
    const row = document.createElement("div");
    row.className = "row" + (file.path === selectedPath ? " on" : "");
    row.addEventListener("click", () => callbacks.onSelect(file.path));

    const status = document.createElement("span");
    status.className = `status ${file.status}`;
    status.textContent = STATUS_LABEL[file.status];
    row.appendChild(status);

    const fn = document.createElement("span");
    fn.className = "fn";
    fn.textContent = file.path;
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

    container.appendChild(row);
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
