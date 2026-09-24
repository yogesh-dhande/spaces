import { WorkspaceSubmodule } from "../bridge/types";
import { ContextMenu, ContextMenuItem } from "./contextMenu";
import { createDisclosureChevron, createDisclosureSpacer, setDisclosureExpanded } from "./disclosureChevron";
import { FolderPicker, workspaceFolderPaths } from "./folderPicker";
import { beginInlineRowEdit, InlineRowEditRequest } from "./inlineRowEditor";
import { buildPathTree, PathTreeDirNode, PathTreeFileNode, PathTreeNode } from "./pathTree";

export interface FilesTreeCallbacks {
  onSelect(path: string): void;
  onExpandedPathsChange?(paths: readonly string[]): void;
  /** Fired after any pointer-menu mutation succeeds (create, rename, move, delete). The tree keeps
   *  no optimistic local state of its own; this is the host's cue to refetch `workspaceFileList`
   *  and re-render, which is the only way a mutation's effect ever reaches this tree. */
  onMutated(): void;
}

/** The workspace listing this tree renders; `workspaceFileList`'s three tree-shaped fields,
 *  bundled so `renderFilesTree` takes one options object instead of positional parameters. */
export interface FilesTreeListing {
  paths: readonly string[];
  submodules: readonly WorkspaceSubmodule[];
  emptyDirectories: readonly string[];
}

/** The mutations the tree's pointer menu performs. Each rejects with the message the tree shows
 *  inline under the row; each resolves only once the daemon has accepted the change. None of them
 *  ever overwrites an existing file or directory: a name that already exists comes back as a
 *  rejection, shown in place, rather than silently replacing what was there. */
export interface FilesTreeActions {
  createFile(path: string): Promise<void>;
  createFolder(path: string): Promise<void>;
  /** Rename and Move to… both land here: the destination is a full workspace-relative path. */
  move(path: string, destinationPath: string): Promise<void>;
  remove(path: string): Promise<void>;
  openInSystemViewer(path: string): Promise<void>;
  /** True once the Editor has reported it cannot open this file as text, which is the only state
   *  in which Open in system viewer has anything to offer. */
  isUnopenable(path: string): boolean;
}

export interface FilesTreeOptions {
  container: HTMLElement;
  listing: FilesTreeListing;
  selectedPath: string | undefined;
  callbacks: FilesTreeCallbacks;
  expandedPaths?: readonly string[];
  contextMenu: ContextMenu;
  /** The overlay Move to… picks its destination folder in; mounted on the pane, like the pointer
   *  menu, so it is never clipped by the sidebar it opens over. */
  folderPicker: FolderPicker;
  actions: FilesTreeActions;
  /** Whether this workspace's files sit on this Mac (`CodePaneInitPayload.isLocalWorkspace`). Open
   *  in system viewer hands a path to macOS, which only exists for a local workspace, so the item is
   *  omitted entirely for a workspace on another device rather than offered and then refused. */
  canOpenInSystemViewer: boolean;
}

/**
 * Refuses a path component the daemon's resolver would silently drop rather than create: an empty
 * segment (from `//`, a leading `/`, or a trailing `/`) or a `.`/`..` segment. Accepting one of these
 * here would let the tree send a noncanonical path (`foo/`, `a//b`) that the daemon resolves to a
 * different, canonical path (`foo`, `a/b`) than the one the tree goes on to open and persist, so
 * every surface keyed by the entered spelling (selection, recents, move retargeting) silently stops
 * matching what is actually on disk. Whitespace is never touched here: a component that is only
 * whitespace, or carries leading/trailing whitespace, has real (non-empty) content and is left to the
 * caller's own blank/unchanged rules. Returns the inline-error message to show, or `undefined` when
 * `value` is fine to send as entered. Shared by New file, New folder, and Rename (see those `commit`
 * callbacks below) so the three entry points enforce one rule rather than three hand-rolled ones.
 * Move to… needs none of this: its destination is picked from folders that already exist rather
 * than typed.
 */
export function invalidPathEntryReason(value: string): string | undefined {
  if (value.includes("//") || value.startsWith("/") || value.endsWith("/")) {
    return "Name can't contain an empty path segment.";
  }
  if (value.split("/").some((segment) => segment === "." || segment === "..")) {
    return "Name can't be \".\" or \"..\".";
  }
  return undefined;
}

/** Returned by `renderFilesTree`; the only way callers touch the tree after the initial paint. */
export interface FilesTreeHandle {
  /** Moves the highlighted row to `path` (expanding and materializing its ancestor chain as
   *  needed) and scrolls it into view, or just clears the previous highlight if `path` is
   *  `undefined` or isn't present in this tree. Never rebuilds already-materialized DOM; see the
   *  module doc comment below. */
  setSelected(path: string | undefined): void;
  expandedPaths(): readonly string[];
  /** Re-keys the remembered expansion onto a confirmed move's destination: the moved directory's
   *  own entry and every entry beneath it. A move is the one change that relocates a directory
   *  without the user touching its disclosure, so without this the refetch that follows would paint
   *  the destination collapsed and keep the source's entries around forever. The path rule is
   *  `pathAfterMove`'s (editorView.ts), spelled out here rather than imported so this module keeps
   *  its imports free of the diff-rendering library. A file move matches no directory entry and so
   *  leaves the set alone. */
  retargetExpandedPaths(from: string, to: string): void;
}

/**
 * Renders Editor mode's "Files" list (the full workspace listing, see `editorSidebar.ts`) into
 * `options.container`. Deliberately the same collapse/indent/row DOM idiom as `fileList.ts`'s Changes
 * list: `.dir-group`/`.dirrow`/`.tri`/`.dirlabel`/`.row`/`.fn`, driven by the same `--depth` CSS
 * custom property; so both lists share almost all of one set of CSS rules in `app.css`, with no
 * `.status` letter or `.st` +/- stat column (every file in the full listing is unchanged by
 * definition: a changed file also appears in the Changes list, which is what carries that
 * information) and, scoped to this tree's own `.files-tree` class on `options.container`, an added
 * `user-select: none` the Changes list's rows don't carry (see the right-click paragraph below).
 *
 * Unlike `fileList.ts`'s Changes tree (small, bounded by how many files are actually dirty) and
 * fully expanded on every render, this listing is capped at 50,000 paths. Materializing every
 * row's DOM and listeners up front, or rebuilding the whole tree on every file open (as this used
 * to do), blocks the WKWebView at that size. So directories render collapsed by default, a
 * directory's children are built into its `.dir-children` element only the first time it is
 * expanded (a collapsed directory that's never opened costs nothing beyond its own `.dirrow`), and
 * `FilesTreeHandle.setSelected` moves the highlight in place, expanding and materializing just the
 * selected path's own ancestor chain instead of re-rendering the tree per selection change. The
 * one eager exception is the initial paint: every ancestor of the given `selectedPath` starts
 * expanded and materialized, so the selected row is already visible and highlighted on first paint
 * rather than requiring a manual expand.
 *
 * Every row, and the tree's own empty background, carries a right-click pointer menu (New file, New
 * folder, and for an existing row, Rename, Move to…, Delete, and, in a workspace whose files are on
 * this Mac, Open in system viewer for a file the Editor cannot open as text). The menu never edits this tree's own model: New/Rename
 * turn a row into an inline text field (`inlineRowEditor.ts`), Move to… opens the folder picker
 * (`folderPicker.ts`) over the pane, and each of them, on a successful commit, calls
 * `FilesTreeOptions.actions` and then `callbacks.onMutated()`; the host refetches the listing and
 * calls `renderFilesTree` again, which is the only way this tree's DOM ever reflects a mutation. A
 * refused mutation renders its message as a `.inline-error` right under the row instead. A row has no
 * text worth copying by selection (Copy path on the row's own menu covers that), so the tree's `.row`/
 * `.dirrow` CSS carries `user-select: none` and a right-click always opens the tree's menu; a row's
 * handler still stops the event from reaching the background's.
 *
 * Because every render replaces the container's contents wholesale, and a refresh arrives whenever
 * workspace file membership changes on the device (not only after this tree's own mutations), the
 * surfaces that outlive a single render have to survive one. Two of them hold a refresh off: an open
 * inline field, whose draft would otherwise be thrown away mid-type, and a row action still awaiting
 * its answer (Move to…, Delete, Open in system viewer), whose row carries the busy state and is where
 * a refusal has to land. A refresh arriving while either is outstanding is held (the most recent one,
 * replacing any earlier held one) and applied when the last of them settles, with a refusal the action
 * settled with repainted under its row by that render rather than swallowed by it. The pointer menu
 * holds nothing but references to rows that are about to be discarded, so any other refresh dismisses
 * it (including the Delete confirmation, which is that same menu reopened) and the folder picker, which
 * holds a row of its own, before replacing the rows they were opened over. That per-container state
 * is the only thing that outlives a single render; see `TreeRenderState`.
 */
export function renderFilesTree(options: FilesTreeOptions): FilesTreeHandle {
  const state = renderStateFor(options.container);
  if (state.holds > 0) {
    // Held, not dropped: replacing the container now would take the focused field and everything typed
    // into it with it, or detach the row an action in flight reports its outcome under. Only the newest
    // listing is worth keeping, so an earlier held one is overwritten.
    state.pendingOptions = options;
    return state.handle;
  }
  // The menu, the Delete confirmation that reuses it, and the folder picker all act on rows of the
  // render being replaced; one left open over the new rows would move or delete something the user is
  // no longer pointing at.
  options.contextMenu.hide();
  options.folderPicker.hide();
  state.current = renderFilesTreeNow(options, state);
  return state.handle;
}

function renderFilesTreeNow(options: FilesTreeOptions, state: TreeRenderState): FilesTreeHandle {
  const { container, listing, selectedPath, callbacks, contextMenu, folderPicker, actions, canOpenInSystemViewer } = options;
  const initiallyExpandedPaths = options.expandedPaths ?? [];
  // Taken here so it is consumed by exactly this render, whether or not that render ends up with a row
  // to paint it under (an empty listing returns below without one).
  const carriedRowError = state.pendingRowError;
  state.pendingRowError = undefined;

  container.replaceChildren();
  // Scopes app.css's `user-select: none` to this tree's rows without touching the `.row`/`.dirrow`
  // rules `fileList.ts`'s Changes list shares with them (see the module doc comment above).
  container.classList.add("files-tree");

  const registry: Registry = { dirs: new Map(), files: new Map() };

  // The tree, not `listing.paths`, decides whether there is anything to show: a workspace whose only
  // listed thing is a submodule checkout (or an empty directory) with no files of its own still has
  // that checkout's/directory's folder.
  const tree = buildPathTree(listing.paths, listing.submodules, listing.emptyDirectories);

  // ---- Pointer-menu action handlers. Declared here (not at module scope) so they close over this
  // render's `registry`/`callbacks`/`actions`/`contextMenu` without threading them through every
  // recursive row-render call below. ----

  function openFileMenu(event: MouseEvent, path: string, row: HTMLElement): void {
    const targetFolder = dirname(path);
    const items: ContextMenuItem[] = [
      { label: "New file", onSelect: () => beginCreate("file", targetFolder) },
      { label: "New folder", onSelect: () => beginCreate("folder", targetFolder) },
      { label: "Rename", onSelect: () => beginRename(path, row) },
      { label: "Move to…", onSelect: () => beginMove(path, row) },
      { label: "Delete", onSelect: () => beginDelete(path, row, event.clientX, event.clientY) },
    ];
    if (canOpenInSystemViewer && actions.isUnopenable(path)) {
      items.push({ label: "Open in system viewer", onSelect: () => void performOpenInSystemViewer(path, row) });
    }
    contextMenu.show({ x: event.clientX, y: event.clientY, header: path, items });
  }

  function openDirMenu(event: MouseEvent, path: string, dirrow: HTMLElement): void {
    const items: ContextMenuItem[] = [
      { label: "New file", onSelect: () => beginCreate("file", path) },
      { label: "New folder", onSelect: () => beginCreate("folder", path) },
      { label: "Rename", onSelect: () => beginRename(path, dirrow) },
      { label: "Move to…", onSelect: () => beginMove(path, dirrow) },
      { label: "Delete", onSelect: () => beginDelete(path, dirrow, event.clientX, event.clientY) },
    ];
    contextMenu.show({ x: event.clientX, y: event.clientY, header: path, items });
  }

  function openBackgroundMenu(event: MouseEvent): void {
    event.preventDefault();
    const items: ContextMenuItem[] = [
      { label: "New file", onSelect: () => beginCreate("file", "") },
      { label: "New folder", onSelect: () => beginCreate("folder", "") },
    ];
    contextMenu.show({ x: event.clientX, y: event.clientY, header: "/", items });
  }
  // Assigned as a property (not addEventListener) so a later renderFilesTree() call on this same
  // container replaces the previous render's handler instead of stacking a duplicate one: every
  // row below is freshly created on each render (replaceChildren() discards the old ones along with
  // their own listeners), but `container` itself persists across renders.
  container.oncontextmenu = openBackgroundMenu;

  /** Runs one inline edit and, for as long as its field is open, holds off any listing refresh that
   *  arrives (see the module doc comment), applying the held one once the field closes. After a
   *  successful commit the held render is redundant, since `onMutated` already refetched, but applying
   *  it is how a refresh that landed for some other reason, or before the refetch, reaches the tree. */
  function runInlineEdit(request: InlineRowEditRequest): void {
    holdRefreshes(state);
    beginInlineRowEdit({
      ...request,
      onClose: () => {
        request.onClose();
        releaseRefreshHold(state);
      },
    });
  }

  function beginCreate(kind: "file" | "folder", targetFolder: string): void {
    registry.dirs.get(targetFolder)?.ensureExpanded();
    const host = targetFolder === "" ? container : registry.dirs.get(targetFolder)?.childrenEl;
    if (!host) return; // the target folder isn't in this tree (a stale menu reference); nothing to insert into
    const depth = targetFolder === "" ? 0 : (registry.dirs.get(targetFolder)?.depth ?? -1) + 1;

    const draft = document.createElement("div");
    draft.className = "row draft";
    draft.style.setProperty("--depth", String(depth));
    host.prepend(draft);

    runInlineEdit({
      row: draft,
      initialValue: "",
      placeholder: kind === "file" ? "New file" : "New folder",
      commit: async (value) => {
        // Trimming decides ONLY whether the field is blank. The path is built from the value
        // verbatim, because a workspace path keeps the whitespace around a name: creating " draft "
        // must make " draft ", not the neighbouring "draft".
        if (value.trim() === "") return; // cancel: nothing typed
        const invalidReason = invalidPathEntryReason(value);
        if (invalidReason !== undefined) throw new Error(invalidReason);
        const path = joinPath(targetFolder, value);
        if (kind === "file") {
          await actions.createFile(path);
          // The open goes first. Both callbacks reach the daemon's per-workspace serial queue, and
          // `onMutated`'s refetch is the whole workspace listing, so posting it first would park the
          // editor's read of the file the user is waiting to see behind it.
          callbacks.onSelect(path); // a newly-created file opens in the editor
          callbacks.onMutated();
        } else {
          await actions.createFolder(path);
          callbacks.onMutated();
        }
      },
      onClose: () => draft.remove(),
    });
  }

  function beginRename(path: string, row: HTMLElement): void {
    const currentName = basename(path);
    const parent = dirname(path);
    runInlineEdit({
      row,
      initialValue: currentName,
      placeholder: "Name",
      commit: async (value) => {
        // Both checks read the field verbatim, and trimming decides only whether it is blank: the
        // destination keeps the whitespace around the typed name, since a workspace path carries it
        // (renaming to " target " makes " target "), and a Return on an untouched field whose name
        // already carries whitespace is unchanged rather than a rename to the trimmed spelling.
        if (value.trim() === "" || value === currentName) return; // cancel: nothing typed, or unchanged
        const invalidReason = invalidPathEntryReason(value);
        if (invalidReason !== undefined) throw new Error(invalidReason);
        await actions.move(path, joinPath(parent, value));
        callbacks.onMutated();
      },
      onClose: () => {},
    });
  }

  /** Move to… asks for a destination folder in the picker overlay, then performs the move itself:
   *  the item keeps its own name and only changes folder, so there is nothing to type. The folder
   *  list is every folder the current listing implies; the picker leaves out the item's own path and
   *  everything under it, and marks the folder it already sits in as unpickable. */
  function beginMove(path: string, row: HTMLElement): void {
    const name = basename(path);
    // Focused before the overlay takes the keyboard, so closing it (Escape, or the move itself) hands
    // focus back to the row the move was started from: a right-click does not focus a row on its own,
    // and the pointer menu hands focus back to whatever held it before the click.
    row.focus();
    folderPicker.show({
      path,
      folders: workspaceFolderPaths(
        listing.paths,
        listing.emptyDirectories,
        listing.submodules.map((submodule) => submodule.path),
      ),
      onChoose: (folder) => void performMove(path, joinPath(folder, name), row),
    });
  }

  /** The move the picker asked for. The row reads as busy until the daemon answers, the way the
   *  inline field this replaced disabled itself mid-commit, and a refusal (a destination that already
   *  exists, a symlinked component, a submodule checkout) lands as a message under the row, the same
   *  slot Delete's own refusal uses. */
  async function performMove(path: string, destinationPath: string, row: HTMLElement): Promise<void> {
    row.classList.add("in-flight");
    row.setAttribute("aria-busy", "true");
    holdRefreshes(state);
    let refusal: string | undefined;
    try {
      await actions.move(path, destinationPath);
      callbacks.onMutated();
    } catch (err) {
      refusal = err instanceof Error ? err.message : String(err);
      showInlineError(row, refusal);
    } finally {
      // A successful move has already replaced these rows via onMutated; clearing the state on a row
      // that is no longer in the tree is harmless, and a refused move's row is still on screen.
      row.classList.remove("in-flight");
      row.removeAttribute("aria-busy");
      releaseRefreshHold(state, refusal === undefined ? undefined : { path, message: refusal });
    }
  }

  /** Every Delete confirms, file or folder, empty-looking or not. A folder row with no rendered
   *  children is NOT evidence of an empty directory: a directory whose entries are all gitignored (a
   *  `logs/` holding only `*.log` files) is reported as one of `listing.emptyDirectories`, and a
   *  checked-out submodule holding no listable file renders childless too. Both hold real bytes, and
   *  the delete takes everything under the path. */
  function beginDelete(path: string, row: HTMLElement, x: number, y: number): void {
    // window.confirm is unavailable here: the WKWebView this pane runs in installs no UI delegate,
    // so window.confirm always and silently returns false instead of prompting. The in-page menu is
    // reused as the confirmation surface in its place, reopened at the same coordinates.
    contextMenu.show({
      x,
      y,
      header: `Delete ${path}?`,
      items: [
        { label: "Delete", onSelect: () => void performDelete(path, row) },
        { label: "Cancel", onSelect: () => {} },
      ],
    });
  }

  async function performDelete(path: string, row: HTMLElement): Promise<void> {
    holdRefreshes(state);
    let refusal: string | undefined;
    try {
      await actions.remove(path);
      callbacks.onMutated();
    } catch (err) {
      refusal = err instanceof Error ? err.message : String(err);
      showInlineError(row, refusal);
    } finally {
      releaseRefreshHold(state, refusal === undefined ? undefined : { path, message: refusal });
    }
  }

  async function performOpenInSystemViewer(path: string, row: HTMLElement): Promise<void> {
    holdRefreshes(state);
    let refusal: string | undefined;
    try {
      await actions.openInSystemViewer(path);
    } catch (err) {
      refusal = err instanceof Error ? err.message : String(err);
      showInlineError(row, refusal);
    } finally {
      releaseRefreshHold(state, refusal === undefined ? undefined : { path, message: refusal });
    }
  }

  // Built before the empty-listing branch below, and reported by that branch's handle too: a pane's
  // very first paint happens before its listing has been fetched, and the caller reads its own copy
  // of the expansion back from whichever handle a render returns (see `EditorSidebar`). A handle that
  // answered with nothing there would therefore erase a restored pane's remembered expansion, and the
  // tree would come back collapsed once the listing did arrive.
  const expandedPaths = new Set(initiallyExpandedPaths);

  function retargetExpandedPaths(from: string, to: string): void {
    const prefix = `${from}/`;
    for (const path of [...expandedPaths]) {
      if (path !== from && !path.startsWith(prefix)) continue;
      expandedPaths.delete(path);
      expandedPaths.add(path === from ? to : to + path.slice(from.length));
    }
  }

  if (tree.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "No files";
    container.appendChild(empty);
    return { setSelected: () => {}, expandedPaths: () => [...expandedPaths], retargetExpandedPaths };
  }

  for (const path of selectedPath !== undefined ? (collectAncestorDirs(tree, selectedPath) ?? []) : []) expandedPaths.add(path);

  // The same directory chrome as fileList.ts's renderDirNode, including its rule that a childless
  // node offers no disclosure: directory rows carry no per-file information, so the two lists' rows
  // are the same code, just duplicated rather than shared across a module boundary for two small,
  // independently-testable renderers (see pathTree.ts's doc comment for the same tradeoff on the
  // tree-building side). Two things differ: the submodule chip is inert here and a selection button
  // in the Changes list, and these rows carry no element id or `data-path`, since nothing addresses a
  // row of the full workspace listing by either.
  function renderDirNode(node: PathTreeDirNode, depth: number): HTMLElement {
    const group = document.createElement("div");
    group.className = "dir-group";

    const dirrow = document.createElement("div");
    dirrow.className = "dirrow";
    dirrow.style.setProperty("--depth", String(depth));

    const childrenEl = document.createElement("div");
    childrenEl.className = "dir-children";

    // A childless directory (a checked-out submodule holding no listable file, or an empty
    // directory named by `emptyDirectories`) is the only kind of node here that can have no
    // children at all (see `buildPathTree`'s seeding). There is nothing to disclose, so it gets no
    // chevron, no button semantics, and no tab stop, rather than a control that opens nothing when
    // activated; its commit chip (if any) below stays, since that is the whole reason a submodule
    // row exists. Same rule as fileList.ts's own directory rows. `ensureExpandedFn` stays the no-op
    // default below: a childless directory needs no expansion to reach; it has nothing to reveal.
    let ensureExpandedFn: () => void = () => {};

    if (node.children.length > 0) {
      dirrow.setAttribute("role", "button");
      dirrow.tabIndex = 0;

      const tri = createDisclosureChevron();
      dirrow.appendChild(tri);

      // Collapsed by default; the one exception is an ancestor of the initial selectedPath, which
      // starts expanded and materialized (see the module doc comment) so the selected row paints
      // visible and highlighted without requiring a manual expand.
      let expanded = expandedPaths.has(node.path);
      let materialized = false;

      const materialize = (): void => {
        if (materialized) return;
        materialized = true;
        for (const child of node.children) {
          childrenEl.appendChild(renderNode(child, depth + 1));
        }
      };

      const applyExpandedState = (): void => {
        childrenEl.style.display = expanded ? "" : "none";
        setDisclosureExpanded(tri, expanded);
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
        event.preventDefault();
        if (event.repeat) return;
        toggle();
      });

      ensureExpandedFn = () => {
        if (!expanded) toggle();
      };
    } else {
      // The same slot, empty, so a childless directory's label lines up with its siblings' labels.
      dirrow.appendChild(createDisclosureSpacer());
    }

    // Registered unconditionally (not just for a directory with children): the pointer menu needs to
    // target a childless directory row too, and New file/New folder need every directory's
    // `.dir-children` host and depth regardless of whether it currently has anything in it.
    registry.dirs.set(node.path, { ensureExpanded: ensureExpandedFn, childrenEl, depth, row: dirrow });

    const label = document.createElement("span");
    label.className = "dirlabel";
    label.textContent = node.label;
    label.title = node.label;
    dirrow.appendChild(label);

    // A submodule checkout is a directory like any other here: it opens, it holds the submodule's
    // files, so the only thing marking it is a commit chip naming what its `HEAD` sits at. Unlike
    // the Changes list's chip this one is inert: there is no pointer row to select in a listing that
    // has no diff behind it.
    if (node.submoduleCommit !== undefined) {
      const chip = document.createElement("span");
      chip.className = "submodule-badge";
      chip.textContent = node.submoduleCommit.slice(0, 7);
      chip.title = `Submodule at ${node.submoduleCommit}`;
      dirrow.appendChild(chip);
    }

    dirrow.addEventListener("contextmenu", (event) => {
      // Stops this from also reaching the container's own contextmenu handler (openBackgroundMenu);
      // a right-click that landed on a row is this row's menu to show, never the background's.
      event.stopPropagation();
      event.preventDefault();
      openDirMenu(event, node.path, dirrow);
    });

    group.appendChild(dirrow);
    group.appendChild(childrenEl);
    return group;
  }

  function renderFileNode(node: PathTreeFileNode, depth: number): HTMLElement {
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
    row.addEventListener("contextmenu", (event) => {
      event.stopPropagation(); // see renderDirNode's identical call for why
      event.preventDefault();
      openFileMenu(event, node.path, row);
    });

    // A file has nothing to disclose, but it takes the same leading slot a directory's chevron
    // occupies, so its name starts in the same column as a sibling folder's label.
    row.appendChild(createDisclosureSpacer());

    const fn = document.createElement("span");
    fn.className = "fn";
    fn.textContent = node.name;
    fn.title = node.path;
    row.appendChild(fn);

    registry.files.set(node.path, row);
    return row;
  }

  function renderNode(node: PathTreeNode, depth: number): HTMLElement {
    return node.kind === "dir" ? renderDirNode(node, depth) : renderFileNode(node, depth);
  }

  for (const node of tree) {
    container.appendChild(renderNode(node, 0));
  }

  if (carriedRowError) {
    const errorRow = registry.files.get(carriedRowError.path) ?? registry.dirs.get(carriedRowError.path)?.row;
    if (errorRow) showInlineError(errorRow, carriedRowError.message);
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
    expandedPaths: () => [...expandedPaths],
    retargetExpandedPaths,
  };
}

/** The only state that outlives a single `renderFilesTree` call, kept per container element (the one
 *  thing a render does not rebuild). It carries the refresh-holding rules from the module doc comment,
 *  plus the stable handle: a caller holds one handle across every render, so a held refresh applied
 *  later cannot leave it pointing at a tree that is no longer on screen. */
interface TreeRenderState {
  /** How many surfaces are holding listing refreshes off right now: an open inline field, and each row
   *  action still awaiting its answer. A count rather than a flag because the tree offers no rule that
   *  only one of them can be outstanding at a time, and a refresh must wait for the last of them. Every
   *  hold ends: a field closes, and every action's host call answers within its own deadline. */
  holds: number;
  /** The newest refresh that arrived while something was holding them off, applied when the last hold
   *  ends. */
  pendingOptions: FilesTreeOptions | undefined;
  /** A refusal a row action settled with, handed to the held render that is about to replace the row it
   *  was painted under. Consumed by the next render, which repaints it under that path's new row, so
   *  applying the held listing does not swallow the only thing telling the user the action was refused.
   *  A render that no longer has a row for the path drops it: an invisible row's message is invisible
   *  either way. */
  pendingRowError: { path: string; message: string } | undefined;
  /** Handed to callers; forwards to whichever render is currently on screen. */
  handle: FilesTreeHandle;
  current: FilesTreeHandle;
}

/** Starts one hold: listing refreshes arriving from here on are kept in `pendingOptions` instead of
 *  replacing the rows the caller is working with. */
function holdRefreshes(state: TreeRenderState): void {
  state.holds += 1;
}

/** Ends one hold and, when it was the last one, applies the newest refresh that arrived meanwhile.
 *  `rowError` is the refusal the settling action ended with, if any; it travels with the render so the
 *  message survives the replacement. */
function releaseRefreshHold(state: TreeRenderState, rowError?: { path: string; message: string }): void {
  state.holds -= 1;
  if (state.holds > 0) return;
  const pending = state.pendingOptions;
  state.pendingOptions = undefined;
  if (!pending) return;
  state.pendingRowError = rowError;
  renderFilesTree(pending);
}

/** Keyed by container so an unmounted tree's state is collected with it. */
const renderStates = new WeakMap<HTMLElement, TreeRenderState>();

function renderStateFor(container: HTMLElement): TreeRenderState {
  const existing = renderStates.get(container);
  if (existing) return existing;
  const state: TreeRenderState = {
    holds: 0,
    pendingOptions: undefined,
    pendingRowError: undefined,
    current: { setSelected: () => {}, expandedPaths: () => [], retargetExpandedPaths: () => {} },
    handle: {
      setSelected: (path) => state.current.setSelected(path),
      expandedPaths: () => state.current.expandedPaths(),
      retargetExpandedPaths: (from, to) => state.current.retargetExpandedPaths(from, to),
    },
  };
  renderStates.set(container, state);
  return state;
}

interface DirControl {
  /** Expands (materializing if needed) this directory if it is currently collapsed; a no-op
   *  otherwise (including for a childless directory, which is never collapsed to begin with; see
   *  `renderDirNode`). Never collapses; only the dirrow's own click/keydown toggle does that. */
  ensureExpanded(): void;
  /** This directory's `.dir-children` host; where New file/New folder insert a draft row. Present
   *  even for a childless directory, which still has (an empty) one. */
  childrenEl: HTMLElement;
  /** This directory's own `.dirrow`; where a refusal carried across a held refresh is repainted. */
  row: HTMLElement;
  /** This directory row's own `--depth`; a new row created inside it renders one level deeper. */
  depth: number;
}

/** Populated as rows are materialized, so `setSelected` and the pointer menu can reach a directory
 *  or file row directly by its full path instead of walking the DOM. Only ever grows; a row, once
 *  materialized, is never removed from the registry (or the DOM) for the lifetime of this render. */
interface Registry {
  dirs: Map<string, DirControl>;
  files: Map<string, HTMLElement>;
}

/**
 * Returns the full path's ancestor directory rows, root-to-leaf, or `undefined` if `path` isn't a
 * file in this tree. A directory's row `path` is its compacted chain's end (see `pathTree.ts`'s
 * `compactDir`), so this returns exactly the rows `setSelected` needs to expand; no intermediate
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

/** `path`'s containing directory, or `""` for a root-level path; mirrors `path.split("/")`
 *  semantics used throughout `pathTree.ts`, just applied to a whole path instead of splitting it. */
function dirname(path: string): string {
  const idx = path.lastIndexOf("/");
  return idx === -1 ? "" : path.slice(0, idx);
}

/** `path`'s final segment; the same value a `PathTreeFileNode.name`/compacted-dir label's last
 *  segment would show. */
function basename(path: string): string {
  const idx = path.lastIndexOf("/");
  return idx === -1 ? path : path.slice(idx + 1);
}

/** Joins a (possibly empty, meaning the workspace root) directory path with a name. */
function joinPath(dir: string, name: string): string {
  return dir === "" ? name : `${dir}/${name}`;
}

/** Renders `message` as a `.inline-error` immediately after `row`; the same visual slot
 *  `inlineRowEditor.ts`'s own rejection path uses, reused here for Delete and Open in system
 *  viewer, neither of which opens a text field to show the error inside of. Replaces a previous
 *  error already sitting there rather than stacking a second one. */
function showInlineError(row: HTMLElement, message: string): void {
  const next = row.nextElementSibling;
  if (next?.classList.contains("inline-error")) next.remove();
  const el = document.createElement("div");
  el.className = "inline-error";
  const depth = row.style.getPropertyValue("--depth");
  if (depth) el.style.setProperty("--depth", depth);
  el.textContent = message;
  row.insertAdjacentElement("afterend", el);
}
