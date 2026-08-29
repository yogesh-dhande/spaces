import { fuzzyMatch } from "./fuzzyMatch";
import { WorkspaceFileListCache } from "./workspaceFileListCache";

const QUICK_OPEN_EMPTY_ID = "code-pane-quick-open-empty";
const QUICK_OPEN_LIST_ID = "code-pane-quick-open-list";

export interface QuickOpenCallbacks {
  /** The pane's current top-level mode, read live at open time — determines which of the two arms
   *  below applies (see this class's doc comment). */
  getMode(): "diff" | "editor";
  /** Whether `path` is in the current diff's changed-file set. Only consulted in Diff mode. */
  isInDiff(path: string): boolean;
  /** Diff mode's own "jump to this file" behavior (`diffView.scrollToFile`) — reused as-is. */
  openInDiff(path: string): void;
  /** Opens `path` in Editor mode, switching modes first if the pane isn't already there. */
  openInEditor(path: string): void;
}

interface QuickOpenResult {
  path: string;
  /** Matched character positions into `path`, for highlighting — empty for the before-typing
   *  "Recent" list, which has nothing to highlight. */
  indices: readonly number[];
}

/**
 * The ⌘P quick-open overlay (Design O): a centered floating panel available in both Diff and
 * Editor mode, replacing Editor mode's old always-visible path input + suggestion dropdown.
 *
 * Before typing, lists `recentPaths` (most-recently-opened first), filtered to paths still present
 * in the workspace listing — a path can leave `recentPaths` only by falling out of the cap (see
 * root.ts's recents bookkeeping), so a deleted file would otherwise still show here. That filter is
 * skipped when the listing is truncated (see `computeRecents`): absence from a partial listing is
 * not evidence a file is gone. While typing,
 * ranks the full workspace listing (from the shared `WorkspaceFileListCache`) by `fuzzyMatch`'s
 * score and highlights each result's matched characters via its returned `indices`.
 *
 * Open semantics (see `QuickOpenCallbacks`): in Editor mode, every open goes straight to the
 * editor. In Diff mode, a file already in the current diff stays in Diff mode and scrolls/jumps
 * there (the same behavior the Changes list's own row click gets); a file outside the diff switches
 * to Editor mode and opens there — there is nothing to jump to in a diff that doesn't include it.
 */
export class QuickOpen {
  private readonly backdropEl: HTMLElement;
  private readonly inputEl: HTMLInputElement;
  private readonly listEl: HTMLElement;
  private readonly noteEl: HTMLElement;

  private isOpen = false;
  private query = "";
  private results: QuickOpenResult[] = [];
  private rowEls: HTMLElement[] = [];
  private selectedIndex = 0;
  /** Whatever had focus just before `show()` moved it to `inputEl`, so `close()` can restore it —
   *  otherwise the hidden input (or, if it was never focused, nothing) strands focus at `<body>` and
   *  keystrokes stop reaching the editor textarea or a keyboard-operable tree row the overlay was
   *  opened on top of, until the user clicks something. `undefined` when nothing needs restoring
   *  (nothing was focused, or the overlay's own input was — see `show()`'s already-open guard). */
  private priorFocusEl: HTMLElement | undefined;

  private listingLoaded = false;
  private cachedPaths: readonly string[] = [];
  private cachedTruncated = false;
  /** Narrowing state for `computeFuzzyMatches`: the previous query and the *full* set of paths
   *  that matched it (not the 50-row render cap). A subsequence match set is monotone — appending
   *  characters to a query can only shrink who still matches, never grow it — so when the current
   *  query extends `lastNarrowedQuery`, only `lastCandidates` needs scoring instead of every cached
   *  path. Empty `lastNarrowedQuery` means "no narrowing state yet"; a fresh, non-extending, or
   *  cleared query resets both alongside recomputing from `cachedPaths`. */
  private lastNarrowedQuery = "";
  private lastCandidates: readonly string[] | undefined = undefined;
  /** Bumped on every `show()`; a listing fetch whose token has been superseded (the overlay was
   *  closed and reopened before the first fetch resolved) drops its result — same latest-wins shape
   *  as root.ts's `diffRequestToken`. */
  private fetchToken = 0;

  constructor(
    host: HTMLElement,
    private readonly fileListCache: WorkspaceFileListCache,
    private readonly getRecentPaths: () => readonly string[],
    private readonly callbacks: QuickOpenCallbacks,
  ) {
    this.backdropEl = document.createElement("div");
    this.backdropEl.className = "quick-open-backdrop";
    this.backdropEl.style.display = "none";
    // Only a click landing directly on the backdrop (not bubbled up from the panel) dismisses —
    // the panel's own mousedown listener below stops that bubbling.
    this.backdropEl.addEventListener("mousedown", (event) => {
      if (event.target === this.backdropEl) this.close();
    });

    const panel = document.createElement("div");
    panel.className = "quick-open";
    panel.addEventListener("mousedown", (event) => event.stopPropagation());

    this.inputEl = document.createElement("input");
    this.inputEl.type = "text";
    this.inputEl.setAttribute("role", "combobox");
    this.inputEl.setAttribute("aria-controls", QUICK_OPEN_LIST_ID);
    this.inputEl.setAttribute("aria-expanded", "true");
    this.inputEl.setAttribute("aria-autocomplete", "list");
    this.inputEl.placeholder = "Open file…";
    this.inputEl.addEventListener("input", () => {
      this.query = this.inputEl.value;
      this.selectedIndex = 0;
      this.renderResults();
    });
    this.inputEl.addEventListener("keydown", (event) => this.handleKeydown(event));

    this.listEl = document.createElement("div");
    this.listEl.className = "list";
    this.listEl.id = QUICK_OPEN_LIST_ID;
    this.listEl.setAttribute("role", "listbox");

    this.noteEl = document.createElement("div");
    this.noteEl.className = "note";
    this.noteEl.textContent = "File list truncated";
    this.noteEl.hidden = true;

    panel.appendChild(this.inputEl);
    panel.appendChild(this.listEl);
    panel.appendChild(this.noteEl);
    this.backdropEl.appendChild(panel);
    host.appendChild(this.backdropEl);

    // Captured at the window level (not on any one focused element) so ⌘P works no matter what has
    // focus in the pane — the host app claims no ⌘P menu item (verified per this feature's design),
    // so there is no competing native handler to defer to.
    window.addEventListener("keydown", (event) => {
      if (event.metaKey && !event.shiftKey && event.key === "p") {
        event.preventDefault();
        this.show();
      }
    });
  }

  show(): void {
    // Guard against ⌘P pressed again while already open: the overlay's own input is what currently
    // has focus in that case, so capturing now would overwrite the real prior element with it.
    if (!this.isOpen) {
      const active = document.activeElement;
      this.priorFocusEl = active instanceof HTMLElement && active !== this.inputEl ? active : undefined;
    }
    this.isOpen = true;
    this.query = "";
    this.inputEl.value = "";
    this.selectedIndex = 0;
    // Seed from the shared cache's last-known-good listing before the synchronous paint below, so an
    // overlay that has never fetched a listing itself (e.g. its first open in Editor mode, after the
    // Files tab already populated the cache) still shows real results instead of empty recents/no
    // matches until its own getFresh() call resolves. Always seed when a snapshot exists: every
    // consumer update flows through a cache resolution that also updated the snapshot, so it's at
    // least as fresh as this instance's own copy. Resets narrowing state the same way a fetch
    // resolution does, since the seeded paths may differ from whatever `lastCandidates` was built
    // against.
    const snapshot = this.fileListCache.snapshot();
    if (snapshot) {
      this.listingLoaded = true;
      this.cachedPaths = snapshot.paths;
      this.cachedTruncated = snapshot.truncated;
      this.lastNarrowedQuery = "";
      this.lastCandidates = undefined;
    }
    this.backdropEl.style.display = "flex";
    this.renderResults();
    this.inputEl.focus();
    this.fetchListing();
  }

  close(): void {
    this.isOpen = false;
    this.backdropEl.style.display = "none";
    // Restore focus to whatever show() found focused, so the editor textarea or a keyboard-operable
    // tree row doesn't strand at <body> after the overlay's hidden input loses focus. Only if it's
    // still connected — the underlying element (e.g. a since-removed tree row) may be gone by now.
    // Any focus the open action itself sets afterwards (openPath's editor open, in particular) runs
    // after this and naturally wins.
    if (this.priorFocusEl?.isConnected) this.priorFocusEl.focus();
    this.priorFocusEl = undefined;
  }

  /** Called by root.ts when the dedicated workspace file-list-signature stream invalidates the
   *  shared `WorkspaceFileListCache`: that cache deliberately keeps serving an in-flight
   *  pre-invalidation promise to callers that already hold it (see WorkspaceFileListCache's doc
   *  comment), so an overlay whose `show()` fetch resolved (or was pending) before the push would
   *  otherwise sit on a stale listing until closed and reopened. This signal is workspace-membership
   *  scoped rather than diff-scope scoped, so it covers Last commit and non-git workspaces too.
   *  No-op while the overlay is closed — nothing is rendering, and the next `show()` fetches fresh
   *  on its own. Applies in both Diff and Editor mode: unlike root.ts's editor-gated sidebar
   *  refresh, the overlay itself is visible in either mode. */
  refreshListing(): void {
    if (!this.isOpen) return;
    this.fetchListing();
  }

  /** Shared by `show()` and `refreshListing()`: fetches a fresh listing through the cache's
   *  token-guarded path and, on resolution, re-renders the current query's results. Bumping the
   *  token here means a `refreshListing()` call always wins over an older, still-pending `show()`
   *  fetch — that older fetch's `token !== this.fetchToken` check drops its result instead of
   *  letting it land after (and undo) the newer one. */
  private fetchListing(): void {
    const token = ++this.fetchToken;
    // getFresh() (not get()): a cached listing from a prior open already renders synchronously above
    // via renderResults()'s use of this.cachedPaths, but it may be stale (see
    // WorkspaceFileListCache.getFresh's doc comment) — this kicks a background revalidation so a file
    // added or removed since then shows up once it resolves, without blanking what's already shown.
    void this.fileListCache
      .getFresh()
      .then((result) => {
        if (token !== this.fetchToken) return; // superseded: closed/reopened before this resolved
        this.listingLoaded = true;
        this.cachedPaths = result.paths;
        this.cachedTruncated = result.truncated;
        // A refreshed listing invalidates any narrowing state built against the old one — a path
        // could be new or renamed and so absent from `lastCandidates` despite matching the current
        // query — so the next keystroke (or this render) must recompute from the fresh `cachedPaths`.
        this.lastNarrowedQuery = "";
        this.lastCandidates = undefined;
        this.renderResults();
      })
      .catch(() => {
        // A failed fetch/revalidation doesn't touch the cache's existing state (see
        // WorkspaceFileListCache.getFresh's doc comment). Before typing, recents still render
        // (computeRecents falls back to unfiltered when !listingLoaded); while typing, fuzzy search
        // just has nothing to match against yet (or keeps showing the last-good listing). The next
        // show() or refreshListing() retries. Swallowed here so it doesn't surface as an unhandled
        // rejection.
      });
  }

  private handleKeydown(event: KeyboardEvent): void {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      if (this.results.length === 0) return;
      const delta = event.key === "ArrowDown" ? 1 : -1;
      this.selectedIndex = Math.max(0, Math.min(this.selectedIndex + delta, this.results.length - 1));
      this.highlightSelection();
      return;
    }
    if (event.key === "Enter") {
      event.preventDefault();
      const selected = this.results[this.selectedIndex];
      if (selected) this.openPath(selected.path);
      return;
    }
    if (event.key === "Escape") {
      event.preventDefault();
      this.close();
    }
  }

  private openPath(path: string): void {
    this.close();
    if (this.callbacks.getMode() === "diff" && this.callbacks.isInDiff(path)) {
      this.callbacks.openInDiff(path);
    } else {
      this.callbacks.openInEditor(path);
    }
  }

  /** Recomputes `this.results` for the current query (recents or fuzzy match) and re-renders the
   *  list from scratch. Only called on open, query change, and a listing fetch resolving — arrow-key
   *  navigation reuses the already-computed `this.results` via `highlightSelection` instead of
   *  recomputing a fuzzy match (over a potentially large workspace listing) on every keypress. */
  private renderResults(): void {
    this.noteEl.hidden = !this.cachedTruncated;
    const trimmed = this.query.trim();
    const isRecents = trimmed.length === 0;
    this.results = isRecents ? this.computeRecents() : this.computeFuzzyMatches(trimmed);
    // A background listing fetch (see show()'s getFresh().then()) can resolve into a shorter result
    // set than the one the user was arrow-keying through — the query-change callers above already
    // reset selectedIndex to 0 before calling in, so this only clamps the async-refresh path.
    this.selectedIndex = Math.min(this.selectedIndex, Math.max(0, this.results.length - 1));
    this.renderRows(isRecents);
  }

  private computeRecents(): QuickOpenResult[] {
    const recents = this.getRecentPaths();
    // Before the listing has loaded there is nothing to filter against yet — show recents
    // unfiltered rather than blanking the list while the (usually fast) lazy fetch is in flight.
    // Also skip filtering when the listing is `truncated`: a recent path's absence from the first
    // 50,000 sorted paths doesn't mean the file is gone, so filtering against a partial listing
    // would wrongly drop valid recents in exactly the huge-workspace case truncation exists for.
    const present = this.listingLoaded && !this.cachedTruncated ? new Set(this.cachedPaths) : undefined;
    const filtered = present ? recents.filter((path) => present.has(path)) : recents;
    return filtered.map((path) => ({ path, indices: [] }));
  }

  private computeFuzzyMatches(query: string): QuickOpenResult[] {
    // Narrowing: if this query only extends the previous one (typing forward, not backspacing or
    // editing mid-string), a path that failed to match the shorter query can never match the
    // longer one either — subsequence matching is monotone in query length — so only the previous
    // query's full match set needs rescoring here, not the entire (up to 50,000-path) listing.
    const candidates =
      this.lastNarrowedQuery.length > 0 && query.startsWith(this.lastNarrowedQuery) && this.lastCandidates
        ? this.lastCandidates
        : this.cachedPaths;

    const scored: { path: string; indices: readonly number[]; score: number }[] = [];
    for (const path of candidates) {
      const match = fuzzyMatch(query, path);
      if (match) scored.push({ path, indices: match.indices, score: match.score });
    }
    scored.sort((a, b) => b.score - a.score);

    this.lastNarrowedQuery = query;
    // The full match set (unsliced), so a longer query later can narrow against it — the 50-row
    // render cap below must not leak into the narrowing state or a match beyond row 50 would
    // wrongly disappear as the query keeps growing.
    this.lastCandidates = scored.map(({ path }) => path);

    // Capped: a very large workspace listing has no reason to render more rows than a user could
    // ever usefully scan, and keeps every render (including the one after each keystroke) cheap.
    return scored.slice(0, 50).map(({ path, indices }) => ({ path, indices }));
  }

  private renderRows(isRecents: boolean): void {
    this.listEl.replaceChildren();
    this.rowEls = [];

    if (this.results.length === 0) {
      this.inputEl.removeAttribute("aria-activedescendant");
      const empty = document.createElement("div");
      empty.className = "empty";
      empty.id = QUICK_OPEN_EMPTY_ID;
      empty.textContent = isRecents ? "No recent files" : "No matches";
      this.listEl.appendChild(empty);
      return;
    }

    if (isRecents) {
      const label = document.createElement("div");
      label.className = "section-label";
      label.textContent = "Recent";
      this.listEl.appendChild(label);
    }

    for (const result of this.results) {
      const row = document.createElement("div");
      row.className = "row";
      row.setAttribute("role", "option");
      row.id = quickOpenResultIdentifier(result.path);
      row.dataset.path = result.path;
      const pathEl = document.createElement("span");
      pathEl.className = "path";
      pathEl.appendChild(renderHighlighted(result.path, result.indices));
      pathEl.title = result.path;
      row.appendChild(pathEl);
      row.addEventListener("click", () => this.openPath(result.path));
      this.listEl.appendChild(row);
      this.rowEls.push(row);
    }
    this.highlightSelection();
  }

  private highlightSelection(): void {
    this.rowEls.forEach((row, index) => {
      const isSelected = index === this.selectedIndex;
      row.classList.toggle("sel", isSelected);
      row.setAttribute("aria-selected", String(isSelected));
      if (isSelected) row.scrollIntoView({ block: "nearest" });
    });
    const selected = this.rowEls[this.selectedIndex];
    if (selected) this.inputEl.setAttribute("aria-activedescendant", selected.id);
    else this.inputEl.removeAttribute("aria-activedescendant");
  }
}

function quickOpenResultIdentifier(path: string): string {
  return `code-pane-quick-open-${encodeURIComponent(path)}`;
}

/** Builds `text` as a fragment with every position in `indices` wrapped in a `<mark>`, coalescing
 *  adjacent matched (or unmatched) runs into single nodes rather than one node per character. */
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
