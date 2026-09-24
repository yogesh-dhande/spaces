import { fuzzyMatch } from "./fuzzyMatch";
import { PickerContent, PickerOverlay, PickerRow } from "./pickerOverlay";
import { WorkspaceFileListCache } from "./workspaceFileListCache";

/** The stem of every id in this overlay; the macOS e2e suite addresses its rows and empty state by
 *  the identifiers `pickerOverlay.ts` builds from it. */
const QUICK_OPEN_ID_PREFIX = "code-pane-quick-open";

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

/**
 * The ⌘P quick-open overlay (Design O): a centered floating panel available in both Diff and
 * Editor mode, replacing Editor mode's old always-visible path input + suggestion dropdown. The
 * panel, its keyboard model, and its match highlighting are `pickerOverlay.ts`'s, shared with the
 * Files tree's Move to… folder picker; everything below is about which paths to offer.
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
  private readonly overlay: PickerOverlay<PickerRow>;

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
    this.overlay = new PickerOverlay<PickerRow>(
      host,
      { panelClass: "quick-open", idPrefix: QUICK_OPEN_ID_PREFIX, placeholder: "Open file…" },
      {
        content: (query) => this.content(query),
        choose: (row) => this.openPath(row.text),
      },
    );

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
    // Seed from the shared cache's last-known-good listing before the overlay's synchronous paint
    // below, so an overlay that has never fetched a listing itself (e.g. its first open in Editor
    // mode, after the Files tab already populated the cache) still shows real results instead of
    // empty recents/no matches until its own getFresh() call resolves. Always seed when a snapshot
    // exists: every consumer update flows through a cache resolution that also updated the snapshot,
    // so it's at least as fresh as this instance's own copy. Resets narrowing state the same way a
    // fetch resolution does, since the seeded paths may differ from whatever `lastCandidates` was
    // built against.
    const snapshot = this.fileListCache.snapshot();
    if (snapshot) {
      this.listingLoaded = true;
      this.cachedPaths = snapshot.paths;
      this.cachedTruncated = snapshot.truncated;
      this.lastNarrowedQuery = "";
      this.lastCandidates = undefined;
    }
    this.overlay.show(undefined);
    this.fetchListing();
  }

  close(): void {
    this.overlay.close();
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
    if (!this.overlay.isOpen()) return;
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
    // via the overlay's use of this.cachedPaths, but it may be stale (see
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
        this.overlay.refresh();
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

  private openPath(path: string): void {
    if (this.callbacks.getMode() === "diff" && this.callbacks.isInDiff(path)) {
      this.callbacks.openInDiff(path);
    } else {
      this.callbacks.openInEditor(path);
    }
  }

  /** The rows for the field's current text: recents before anything is typed, fuzzy matches after.
   *  Called by the overlay on open, on every keystroke, and on a listing fetch resolving; arrow-key
   *  navigation never reaches here, so it never recomputes a fuzzy match (over a potentially large
   *  workspace listing) on a keypress that only moves the highlight. */
  private content(query: string): PickerContent<PickerRow> {
    const trimmed = query.trim();
    const isRecents = trimmed.length === 0;
    const rows = isRecents ? this.computeRecents() : this.computeFuzzyMatches(trimmed);
    return {
      rows,
      sectionLabel: isRecents ? "Recent" : undefined,
      emptyText: isRecents ? "No recent files" : "No matches",
      note: this.cachedTruncated ? "File list truncated" : undefined,
    };
  }

  private computeRecents(): PickerRow[] {
    const recents = this.getRecentPaths();
    // Before the listing has loaded there is nothing to filter against yet — show recents
    // unfiltered rather than blanking the list while the (usually fast) lazy fetch is in flight.
    // Also skip filtering when the listing is `truncated`: a recent path's absence from the first
    // 50,000 sorted paths doesn't mean the file is gone, so filtering against a partial listing
    // would wrongly drop valid recents in exactly the huge-workspace case truncation exists for.
    const present = this.listingLoaded && !this.cachedTruncated ? new Set(this.cachedPaths) : undefined;
    const filtered = present ? recents.filter((path) => present.has(path)) : recents;
    // Nothing to highlight in a list nothing was typed against.
    return filtered.map((path) => ({ text: path, indices: [], selectable: true }));
  }

  private computeFuzzyMatches(query: string): PickerRow[] {
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
    return scored.slice(0, 50).map(({ path, indices }) => ({ text: path, indices, selectable: true }));
  }
}
