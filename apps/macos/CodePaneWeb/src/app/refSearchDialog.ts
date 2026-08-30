import { WorkspaceRefListResult } from "../bridge/types";
import { fuzzyMatch } from "./fuzzyMatch";

/** Which of the two "search a ref" flows the dialog is opened in — set fresh on every `show()`
 *  call from `toolbar.ts`'s "Branch…" / "Commit or ref…" compare-menu items. */
export type RefSearchMode = "branch" | "ref";

export interface RefSearchDialogCallbacks {
  /** A ref was picked: a branch name, a commit's full sha, or (in `ref` mode, when nothing in the
   *  listing matched) the query typed verbatim. The caller dispatches
   *  `setScope({kind: "ref", refName})`. */
  onSelect(refName: string): void;
}

interface BranchRow {
  kind: "branch";
  name: string;
  isBase: boolean;
  indices: readonly number[];
}

interface CommitRow {
  kind: "commit";
  sha: string;
  subject: string;
}

interface LiteralRow {
  kind: "literal";
  query: string;
}

type Row = BranchRow | CommitRow | LiteralRow;

/**
 * The "Branch…" / "Commit or ref…" search overlay opened from the toolbar's compare menu (see
 * `toolbar.ts`). Styled and structured like the ⌘P quick-open overlay (`quickOpen.ts`) — same
 * backdrop/panel/input/list shape, same Escape-closes/focus-restore discipline — but simpler in a
 * couple of ways this dialog's data doesn't need: the listing is fetched fresh on every `show()`
 * (no cache, no narrowing optimization — a workspace's branch list and recent-commit history are
 * small enough that a full rescan per keystroke is cheap, unlike ⌘P's up-to-50,000-path listing),
 * and there is no window-level keydown listener registered at construction — this dialog only ever
 * opens because a compare-menu item calls `show()` directly, so ⌘P's own global listener has
 * nothing to conflict with here.
 */
export class RefSearchDialog {
  private readonly backdropEl: HTMLElement;
  private readonly inputEl: HTMLInputElement;
  private readonly listEl: HTMLElement;
  private readonly noteEl: HTMLElement;

  private isOpen = false;
  private mode: RefSearchMode = "branch";
  private query = "";
  private rows: Row[] = [];
  private rowEls: HTMLElement[] = [];
  private selectedIndex = 0;

  private loaded = false;
  private branches: string[] = [];
  private branchesTruncated = false;
  private commits: { sha: string; subject: string }[] = [];
  private commitsTruncated = false;

  /** Whatever had focus just before `show()` moved it to `inputEl` — mirrors
   *  `QuickOpen.priorFocusEl`'s doc comment verbatim: `close()` restores it so the pane doesn't
   *  strand focus at `<body>`, and the already-open guard in `show()` keeps a second open (which
   *  can't currently happen — nothing re-shows an already-open dialog — from overwriting it with
   *  the dialog's own input). */
  private priorFocusEl: HTMLElement | undefined;

  /** Bumped on every `show()`; a `workspaceRefList` reply whose token has been superseded (closed
   *  and reopened, in either mode, before it resolved) drops its result — same latest-wins shape as
   *  `QuickOpen.fetchToken`. */
  private fetchToken = 0;

  constructor(
    host: HTMLElement,
    private readonly listRefs: () => Promise<WorkspaceRefListResult>,
    private readonly baseBranch: string | undefined,
    private readonly callbacks: RefSearchDialogCallbacks,
  ) {
    this.backdropEl = document.createElement("div");
    this.backdropEl.className = "quick-open-backdrop";
    this.backdropEl.style.display = "none";
    this.backdropEl.addEventListener("mousedown", (event) => {
      if (event.target === this.backdropEl) this.close();
    });

    const panel = document.createElement("div");
    panel.className = "quick-open ref-search";
    panel.addEventListener("mousedown", (event) => event.stopPropagation());

    this.inputEl = document.createElement("input");
    this.inputEl.type = "text";
    this.inputEl.addEventListener("input", () => {
      this.query = this.inputEl.value;
      this.selectedIndex = 0;
      this.renderResults();
    });
    this.inputEl.addEventListener("keydown", (event) => this.handleKeydown(event));

    this.listEl = document.createElement("div");
    this.listEl.className = "list";

    this.noteEl = document.createElement("div");
    this.noteEl.className = "note";
    this.noteEl.hidden = true;

    panel.appendChild(this.inputEl);
    panel.appendChild(this.listEl);
    panel.appendChild(this.noteEl);
    this.backdropEl.appendChild(panel);
    host.appendChild(this.backdropEl);
  }

  /** Opens in `mode` — called only from `toolbar.ts`'s "Branch…" / "Commit or ref…" menu items. */
  show(mode: RefSearchMode): void {
    if (!this.isOpen) {
      const active = document.activeElement;
      this.priorFocusEl = active instanceof HTMLElement && active !== this.inputEl ? active : undefined;
    }
    this.isOpen = true;
    this.mode = mode;
    this.query = "";
    this.inputEl.value = "";
    this.inputEl.placeholder = mode === "branch" ? "Search branches…" : "Commit SHA, tag, or branch…";
    this.selectedIndex = 0;
    this.loaded = false;
    this.backdropEl.style.display = "flex";
    this.renderResults();
    this.inputEl.focus();
    this.fetchListing();
  }

  close(): void {
    this.isOpen = false;
    this.backdropEl.style.display = "none";
    if (this.priorFocusEl?.isConnected) this.priorFocusEl.focus();
    this.priorFocusEl = undefined;
  }

  /** Fetched fresh on every `show()` — no cache, per this class's doc comment. */
  private fetchListing(): void {
    const token = ++this.fetchToken;
    void this.listRefs()
      .then((result) => {
        if (token !== this.fetchToken) return; // superseded: closed/reopened before this resolved
        this.loaded = true;
        this.branches = result.branches;
        this.branchesTruncated = result.branchesTruncated;
        this.commits = result.commits;
        this.commitsTruncated = result.commitsTruncated;
        this.renderResults();
      })
      .catch(() => {
        // Swallowed like QuickOpen's own listing fetch: the panel just stays on its "Loading…" state
        // (or, in ref mode, on the always-available literal row) until the next show() retries.
      });
  }

  private handleKeydown(event: KeyboardEvent): void {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      if (this.rows.length === 0) return;
      const delta = event.key === "ArrowDown" ? 1 : -1;
      this.selectedIndex = Math.max(0, Math.min(this.selectedIndex + delta, this.rows.length - 1));
      this.highlightSelection();
      return;
    }
    if (event.key === "Enter") {
      event.preventDefault();
      const row = this.rows[this.selectedIndex];
      if (row) this.selectRow(row);
      return;
    }
    if (event.key === "Escape") {
      event.preventDefault();
      this.close();
    }
  }

  private selectRow(row: Row): void {
    const refName = row.kind === "branch" ? row.name : row.kind === "commit" ? row.sha : row.query;
    this.close();
    this.callbacks.onSelect(refName);
  }

  /** Recomputes `this.rows` for the current query and mode, and re-renders the list from scratch. */
  private renderResults(): void {
    const trimmed = this.query.trim();
    this.rows = this.mode === "branch" ? this.computeBranchRows(trimmed) : this.computeCommitRows(trimmed);
    this.selectedIndex = Math.min(this.selectedIndex, Math.max(0, this.rows.length - 1));
    this.renderRows();
  }

  private computeBranchRows(query: string): BranchRow[] {
    if (!this.loaded) return [];
    // Workspaces store their configured base as the bare branch name, while a branch that only
    // exists as a remote-tracking ref is deliberately listed under its resolvable `origin/` name.
    // Prefer the bare entry when both exist; otherwise treat its origin-prefixed counterpart as the
    // configured base so remote-only bases receive the same badge and first-sort behavior.
    const listedBaseBranch = this.baseBranch
      ? this.branches.includes(this.baseBranch)
        ? this.baseBranch
        : this.branches.includes(`origin/${this.baseBranch}`)
          ? `origin/${this.baseBranch}`
          : undefined
      : undefined;
    const matched: { name: string; indices: readonly number[] }[] = [];
    for (const name of this.branches) {
      if (query.length === 0) {
        matched.push({ name, indices: [] });
        continue;
      }
      const match = fuzzyMatch(query, name);
      if (match) matched.push({ name, indices: match.indices });
    }
    // The base branch sorts first whenever it's still among the matches — everything else keeps its
    // listing order. Branch names are few enough (unlike ⌘P's tens-of-thousands-of-paths search)
    // that ranking differences between them are rarely meaningful beyond that one case.
    matched.sort((a, b) => {
      const aBase = a.name === listedBaseBranch;
      const bBase = b.name === listedBaseBranch;
      if (aBase !== bBase) return aBase ? -1 : 1;
      return 0;
    });
    return matched.map(({ name, indices }) => ({ kind: "branch", name, isBase: name === listedBaseBranch, indices }));
  }

  private computeCommitRows(query: string): Row[] {
    const rows: Row[] = [];
    if (this.loaded) {
      const lowerQuery = query.toLowerCase();
      for (const commit of this.commits) {
        const matchesSha = query.length > 0 && commit.sha.toLowerCase().startsWith(lowerQuery);
        const matchesSubject = query.length === 0 || fuzzyMatch(query, commit.subject) !== null;
        if (matchesSha || matchesSubject) rows.push({ kind: "commit", sha: commit.sha, subject: commit.subject });
      }
    }
    // Offered only once history has loaded and nothing matches, so a subject/SHA search presents its
    // valid commit result without a misleading same-text invalid-ref action. An arbitrary ref/tag/sha
    // absent from recent history remains reachable, with validation left to the diff request.
    if (this.loaded && query.length > 0 && rows.length === 0) rows.push({ kind: "literal", query });
    return rows;
  }

  private renderRows(): void {
    this.listEl.replaceChildren();
    this.rowEls = [];

    const truncated = this.loaded && (this.mode === "branch" ? this.branchesTruncated : this.commitsTruncated);
    this.noteEl.hidden = !truncated;
    if (truncated) {
      this.noteEl.textContent = this.mode === "branch" ? "Branch list truncated" : "Commit history truncated";
    }

    if (!this.loaded && this.rows.length === 0) {
      const loading = document.createElement("div");
      loading.className = "empty";
      loading.textContent = "Loading…";
      this.listEl.appendChild(loading);
      return;
    }

    if (this.rows.length === 0) {
      const empty = document.createElement("div");
      empty.className = "empty";
      empty.textContent = this.mode === "branch" ? "No matching branches" : "No matching commits";
      this.listEl.appendChild(empty);
      return;
    }

    for (const row of this.rows) {
      const rowEl = document.createElement("div");
      rowEl.className = "row";
      if (row.kind === "branch") {
        const nameEl = document.createElement("span");
        nameEl.className = "path";
        nameEl.appendChild(renderHighlighted(row.name, row.indices));
        rowEl.appendChild(nameEl);
        if (row.isBase) {
          const badge = document.createElement("span");
          badge.className = "badge";
          badge.textContent = "base";
          rowEl.appendChild(badge);
        }
      } else if (row.kind === "commit") {
        const shaEl = document.createElement("span");
        shaEl.className = "sha";
        shaEl.textContent = row.sha.slice(0, 7);
        const subjectEl = document.createElement("span");
        subjectEl.className = "subject";
        subjectEl.textContent = row.subject;
        rowEl.appendChild(shaEl);
        rowEl.appendChild(subjectEl);
      } else {
        rowEl.classList.add("literal");
        rowEl.textContent = `Use '${row.query}'`;
      }
      rowEl.addEventListener("click", () => this.selectRow(row));
      this.listEl.appendChild(rowEl);
      this.rowEls.push(rowEl);
    }
    this.highlightSelection();
  }

  private highlightSelection(): void {
    this.rowEls.forEach((rowEl, index) => {
      const isSelected = index === this.selectedIndex;
      rowEl.classList.toggle("sel", isSelected);
      if (isSelected) rowEl.scrollIntoView({ block: "nearest" });
    });
  }
}

/** Builds `text` as a fragment with every position in `indices` wrapped in a `<mark>`, coalescing
 *  adjacent matched (or unmatched) runs into single nodes rather than one node per character.
 *  Duplicated from `quickOpen.ts`'s identical helper: small enough (a dozen lines) not to warrant a
 *  shared module for its only two call sites. */
function renderHighlighted(text: string, indices: readonly number[]): DocumentFragment {
  const frag = document.createDocumentFragment();
  const matched = new Set(indices);
  let buf = "";
  let bufIsMatch = false;
  const flush = (): void => {
    if (!buf) return;
    if (bufIsMatch) {
      const mark = document.createElement("mark");
      mark.textContent = buf;
      frag.appendChild(mark);
    } else {
      frag.appendChild(document.createTextNode(buf));
    }
    buf = "";
  };
  for (let i = 0; i < text.length; i++) {
    const isMatch = matched.has(i);
    if (buf && isMatch !== bufIsMatch) flush();
    bufIsMatch = isMatch;
    buf += text[i];
  }
  flush();
  return frag;
}
