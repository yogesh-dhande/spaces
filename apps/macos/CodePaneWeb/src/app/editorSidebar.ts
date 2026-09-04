import { FilesTreeHandle, renderFilesTree } from "./filesTree";
import { WorkspaceFileListCache } from "./workspaceFileListCache";

export type EditorSidebarMode = "files" | "changes";

export interface EditorSidebarCallbacks {
  /** Fired whenever the Files/Changes toggle is clicked to a new value — root.ts persists this into
   *  `CodePaneEditorUIState.sidebarMode` and, for "changes", makes sure the diff has actually been
   *  fetched at least once (see root.ts's `onModeChange` wiring). */
  onModeChange(mode: EditorSidebarMode): void;
  onTreeStateChange?(state: { expandedPaths: readonly string[]; selectedPath: string | undefined }): void;
}

/**
 * Editor mode's sidebar: a two-way "Files" / "Changes" segmented header (Design K) sitting inside
 * the same `.file-list` element diff mode's plain changed-files list occupies — root.ts swaps
 * `fileListEl`'s single child between this instance's `el` (editor mode) and the changed-files list
 * host directly (diff mode, no header, unchanged from before Design K).
 *
 * "Files" renders the full workspace listing (`filesTree.ts`, fed lazily from the shared
 * `WorkspaceFileListCache`) with no per-file status — every file in that listing is unchanged by
 * definition, since a changed file also appears in the Changes list, which is what carries that
 * information. "Changes" reparents the SAME DOM node root.ts's own `renderFileList` calls already
 * target (`changesListEl`, passed in by reference) — its rows and their click behavior are entirely
 * owned by root.ts, this class only moves the node in and out of its own list host. Reparenting an
 * already-rendered node preserves its content and listeners; it does not require re-rendering.
 */
export class EditorSidebar {
  readonly el: HTMLElement;
  private readonly headerEl: HTMLElement;
  private readonly filesBtn: HTMLButtonElement;
  private readonly changesBtn: HTMLButtonElement;
  private readonly listHostEl: HTMLElement;
  private readonly filesTreeEl: HTMLElement;
  private readonly noteEl: HTMLElement;

  private mode: EditorSidebarMode;
  private readonly changesAvailable: boolean;
  private selectedPath: string | undefined;
  private paths: readonly string[] = [];
  private truncated = false;
  /** Handle from the last full `renderFilesTreeNow()` render — lets `setSelectedPath` move the
   *  highlight in place instead of rebuilding the whole tree (see its own doc comment). `undefined`
   *  only before the first render, which the constructor always performs. */
  private filesTreeHandle: FilesTreeHandle | undefined;
  /** Bumped at the start of every listing fetch; a fetch whose token has been superseded (a later
   *  fetch, or this instance moving off the Files tab before the first one resolved) drops its
   *  result rather than overwriting a newer one — same latest-wins shape as root.ts's
   *  `diffRequestToken`. */
  private fetchToken = 0;
  private expandedPaths: readonly string[];

  constructor(
    private readonly changesListEl: HTMLElement,
    private readonly fileListCache: WorkspaceFileListCache,
    initial: {
      sidebarMode: EditorSidebarMode;
      selectedPath: string | undefined;
      expandedPaths?: readonly string[];
      /** False for a workspace whose project is not a git repository: it has no changed-file list,
       *  so this sidebar carries the Files tree alone and renders no segmented header at all. */
      changesAvailable: boolean;
    },
    private readonly onSelectFile: (path: string) => void,
    private readonly callbacks: EditorSidebarCallbacks,
  ) {
    this.changesAvailable = initial.changesAvailable;
    this.mode = initial.changesAvailable ? initial.sidebarMode : "files";
    this.selectedPath = initial.selectedPath;
    this.expandedPaths = initial.expandedPaths ?? [];

    this.el = document.createElement("div");
    this.el.className = "editor-sidebar";

    this.headerEl = document.createElement("div");
    this.headerEl.className = "editor-sidebar-hdr";
    const seg = document.createElement("span");
    seg.className = "seg";
    this.filesBtn = document.createElement("button");
    this.filesBtn.type = "button";
    this.filesBtn.textContent = "Files";
    this.filesBtn.addEventListener("click", () => this.setMode("files"));
    this.changesBtn = document.createElement("button");
    this.changesBtn.type = "button";
    this.changesBtn.textContent = "Changes";
    this.changesBtn.addEventListener("click", () => this.setMode("changes"));
    seg.appendChild(this.filesBtn);
    seg.appendChild(this.changesBtn);
    this.headerEl.appendChild(seg);

    this.listHostEl = document.createElement("div");
    this.listHostEl.className = "editor-sidebar-list";

    this.filesTreeEl = document.createElement("div");

    this.noteEl = document.createElement("div");
    this.noteEl.className = "editor-sidebar-note";
    this.noteEl.textContent = "File list truncated";
    this.noteEl.hidden = true;

    if (this.changesAvailable) this.el.appendChild(this.headerEl);
    this.el.appendChild(this.listHostEl);
    this.el.appendChild(this.noteEl);

    this.updateHeaderSelection();
    // Mounts the current tab's chrome WITHOUT starting a listing fetch: every pane constructs an
    // EditorSidebar unconditionally, including panes whose top-level mode is Diff (where this
    // sidebar isn't even attached to the DOM) — starting `fileListCache.getFresh()`'s up-to-50,000-path
    // `workspaceFileList` RPC here would run it on the daemon's shared per-workspace serial git queue
    // for every diff-only pane too, ahead of/alongside its actual `workspaceDiffManifestChunk` pull. The first fetch is
    // deferred to whenever this sidebar is actually shown instead: `reattach()` (root.ts calls it on
    // every diff→editor transition, and once more after the very first render for a pane that starts
    // or rehydrates directly into editor mode — see root.ts) and the Files/Changes toggle's
    // `setMode()`.
    this.mountCurrentMode();
  }

  getMode(): EditorSidebarMode {
    return this.mode;
  }

  /** Called by root.ts whenever the open file changes (including on every diff refresh, to
   *  re-highlight the selected row if the Changes list is showing). The changed-files rows
   *  themselves are re-rendered by root.ts's own `renderFileList` call — this only concerns this
   *  sidebar's own toggle chrome, which does not need to change just because the diff refreshed.
   *  On the Files tab, this moves the highlight in place via `FilesTreeHandle.setSelected` rather
   *  than re-rendering the tree — `renderFilesTreeNow()` still runs on every fetch-resolution and
   *  mount path (which pass `this.selectedPath` through so the selection is pre-revealed there),
   *  just not here, since re-running it on every file open is exactly the per-selection full rebuild
   *  this handle exists to avoid. */
  setSelectedPath(path: string | undefined): void {
    this.selectedPath = path;
    if (this.mode !== "files") return;
    // mountCurrentMode() always runs renderFilesTreeNow() (setting filesTreeHandle) before mode can
    // ever be observed as "files" — by the constructor if it starts there, or by setMode/renderList
    // before the mode assignment they follow takes effect for any caller.
    this.filesTreeHandle!.setSelected(path);
    this.expandedPaths = this.filesTreeHandle!.expandedPaths();
    this.callbacks.onTreeStateChange?.({ expandedPaths: this.expandedPaths, selectedPath: this.selectedPath });
  }

  /** Called by root.ts after invalidating the shared `WorkspaceFileListCache` from the dedicated
   *  workspace file-list-signature stream, so files added or removed elsewhere reappear without a
   *  manual refresh even when the active diff scope would not change. root.ts only calls this while
   *  the PANE's own mode is "editor" — this sidebar isn't even in the DOM in Diff mode, so a call
   *  here would otherwise fire a full workspace listing fetch for nothing. A no-op while the
   *  Changes tab is showing — the Files tab re-fetches on demand the next time it's selected (see
   *  `setMode`, and `reattach` below for the diff→editor transition specifically), since
   *  `WorkspaceFileListCache` itself was already invalidated by the caller and will fetch fresh on
   *  the next `get()` either way. */
  refreshFilesListing(): void {
    if (this.mode === "files") this.renderList();
  }

  /** Re-renders this sidebar's current-mode list from scratch. root.ts calls this on every
   *  diff→editor mode transition: Diff mode's own `fileListEl.replaceChildren(changesListEl)`
   *  reparents `changesListEl` OUT of this sidebar's list host without this instance ever knowing —
   *  it isn't even attached to the DOM while the pane is in Diff mode — so returning to Editor mode
   *  on the Changes tab would otherwise show an empty list until the user manually toggled tabs.
   *  Re-running `renderList()` here reparents `changesListEl` back in for "changes", or re-fetches
   *  from the shared cache for "files" — which also picks up anything invalidated by a workspace
   *  file-list-signature push that arrived while this sidebar was off-screen (see
   *  `refreshFilesListing()` above). */
  reattach(): void {
    this.renderList();
  }

  private setMode(mode: EditorSidebarMode): void {
    // The header these buttons live on isn't rendered at all without a Changes tab; the guard makes
    // the tab unreachable rather than merely unclickable.
    if (mode === "changes" && !this.changesAvailable) return;
    if (mode === this.mode) return;
    this.mode = mode;
    this.updateHeaderSelection();
    this.renderList();
    this.callbacks.onModeChange(mode);
  }

  private updateHeaderSelection(): void {
    this.filesBtn.classList.toggle("on", this.mode === "files");
    this.changesBtn.classList.toggle("on", this.mode === "changes");
  }

  /** Mounts the current tab's host node into `listHostEl` and, for "files", paints whatever
   *  `this.paths`/`this.truncated` already hold — no fetch. Shared by the constructor (which must
   *  never fetch, see its own doc comment) and `renderList()` below (which mounts the same way before
   *  deciding whether to fetch). Painting the note here (not just in the fetch's `.then()`) keeps it
   *  in sync with the same cached snapshot the tree renders from: without this, switching back to
   *  Files from Changes would show a truncated cached listing with the note still hidden until a
   *  slow or failed revalidation resolves.
   *
   *  Before painting, seeds `this.paths`/`this.truncated` from the shared cache's `snapshot()` when
   *  one exists — this instance's own copy is empty on a Files tab that has never fetched a listing
   *  itself (its very first mount, or a first show reached before another consumer, like the ⌘P
   *  overlay in Diff mode, ever populated it here), even though the cache already holds a perfectly
   *  good listing fetched by that other consumer. Always seed when a snapshot exists: it's at least
   *  as fresh as this instance's own `this.paths`, since every consumer update flows through a cache
   *  resolution that also updated the snapshot. */
  private mountCurrentMode(): void {
    this.listHostEl.replaceChildren();
    if (this.mode === "changes") {
      this.listHostEl.appendChild(this.changesListEl);
      return;
    }
    this.listHostEl.appendChild(this.filesTreeEl);
    const snapshot = this.fileListCache.snapshot();
    if (snapshot) {
      this.paths = snapshot.paths;
      this.truncated = snapshot.truncated;
    }
    this.renderFilesTreeNow();
    this.noteEl.hidden = !this.truncated;
  }

  private renderList(): void {
    this.mountCurrentMode();
    if (this.mode === "changes") {
      // Bump fetchToken so a Files fetch still in flight from before this switch can't land here: its
      // `.then()`'s `token !== this.fetchToken` guard now fails, so it can no longer flip
      // `noteEl.hidden` (or overwrite `paths`/`truncated`) underneath the Changes list it no longer
      // applies to (Finding 2).
      this.fetchToken++;
      this.noteEl.hidden = true;
      return;
    }
    const token = ++this.fetchToken;
    // getFresh() (not get()): renderList() runs on every Files-tab "show" (tab switch, reattach() on
    // editor re-entry) — the moments this sidebar must revalidate at before the dedicated
    // file-list-signature stream has fired for this pane, and after any invalidation that arrived
    // while it was off-screen. renderFilesTreeNow() above already painted whatever this.paths last
    // held, so a stale cached value keeps showing while this resolves rather than the tree going blank.
    void this.fileListCache
      .getFresh()
      .then((result) => {
        if (token !== this.fetchToken) return; // superseded by a later fetch, or the tab moved off Files
        this.paths = result.paths;
        this.truncated = result.truncated;
        this.renderFilesTreeNow();
        this.noteEl.hidden = !this.truncated;
      })
      .catch(() => {
        // A failed fetch/revalidation doesn't touch the cache's existing state (see
        // WorkspaceFileListCache.getFresh's doc comment), so the Files tree just stays on whatever it
        // last had (empty, on a first-ever failure) rather than showing an error of its own — the
        // next tab visit or workspace file-list-signature push retries. Swallowed here so it doesn't
        // surface as an unhandled rejection.
      });
  }

  private renderFilesTreeNow(): void {
    this.filesTreeHandle = renderFilesTree(this.filesTreeEl, this.paths, this.selectedPath, {
      onSelect: (path) => this.onSelectFile(path),
      onExpandedPathsChange: (expandedPaths) => {
        this.expandedPaths = expandedPaths;
        this.callbacks.onTreeStateChange?.({ expandedPaths, selectedPath: this.selectedPath });
      },
    }, this.expandedPaths);
    this.expandedPaths = this.filesTreeHandle.expandedPaths();
  }
}
