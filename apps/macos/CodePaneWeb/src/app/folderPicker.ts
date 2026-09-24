import { fuzzyMatch } from "./fuzzyMatch";
import { PickerContent, PickerOverlay, PickerRow } from "./pickerOverlay";

/** One destination row: the folder it names, plus the `PickerRow` shape the overlay renders. */
interface FolderRow extends PickerRow {
  /** Workspace-relative; `""` is the workspace root, which the row shows as `/`. */
  folder: string;
}

export interface FolderPickerRequest {
  /** The item being moved, workspace-relative. Its basename names the picker and rides along to the
   *  destination; its own path and everything under it stay out of the list, since a folder cannot
   *  be moved inside itself. */
  path: string;
  /** Every folder in the workspace listing, the root (`""`) included, in the order they are listed;
   *  see `workspaceFolderPaths`. */
  folders: readonly string[];
  /** The chosen destination folder, `""` for the workspace root. Never the folder `path` already
   *  sits in: that row is listed for orientation and cannot be picked. */
  onChoose(folder: string): void;
}

/** What a row shows for the workspace root, which has no path of its own to print. */
const ROOT_LABEL = "/";

/**
 * The Files tree's Move to… destination picker: the same centered overlay ⌘P quick-open uses (see
 * `pickerOverlay.ts`), listing the workspace's folders instead of its files. The item's current
 * parent folder heads the list, marked and unpickable, so the user can see where the item is
 * without being able to "move" it there; typing fuzzy-filters the rest; Return moves, Escape closes
 * and hands focus back to the row the menu was opened on.
 *
 * Picking a folder is all this surface does. The move itself, its in-flight state on the row, and a
 * refusal's message stay with the tree (`filesTree.ts`), which is what owns the row.
 */
export class FolderPicker {
  private readonly overlay: PickerOverlay<FolderRow>;
  /** The rows of the open request, before the field's text filters them. */
  private candidates: readonly FolderRow[] = [];
  private onChoose: (folder: string) => void = () => {};

  constructor(host: HTMLElement) {
    this.overlay = new PickerOverlay<FolderRow>(
      host,
      {
        panelClass: "quick-open folder-picker",
        idPrefix: "code-pane-folder-picker",
        placeholder: "Search folders…",
      },
      {
        content: (query) => this.content(query),
        choose: (row) => this.onChoose(row.folder),
      },
    );
  }

  show(request: FolderPickerRequest): void {
    const currentFolder = dirname(request.path);
    const descendantPrefix = `${request.path}/`;
    const rest = request.folders.filter(
      (folder) => folder !== currentFolder && folder !== request.path && !folder.startsWith(descendantPrefix),
    );
    // The current parent is built here rather than kept in place, so it heads the list whatever its
    // path's sort order is: it is the one row the user reads to know where the item is coming from.
    this.candidates = [
      { folder: currentFolder, text: labelFor(currentFolder), indices: [], badge: "current", selectable: false },
      ...rest.map((folder) => ({ folder, text: labelFor(folder), indices: [], selectable: true })),
    ];
    this.onChoose = request.onChoose;
    this.overlay.show(moveTitle(basename(request.path)));
  }

  /** Closes with no choice made. The tree calls this when a listing refresh replaces the rows this
   *  picker was opened over, the same way it dismisses the pointer menu. */
  hide(): void {
    this.overlay.close();
  }

  private content(query: string): PickerContent<FolderRow> {
    const trimmed = query.trim();
    if (trimmed.length === 0) return { rows: this.candidates, emptyText: "No folders" };
    const rows: FolderRow[] = [];
    for (const candidate of this.candidates) {
      const match = fuzzyMatch(trimmed, candidate.text);
      if (match) rows.push({ ...candidate, indices: match.indices });
    }
    return { rows, emptyText: "No matching folders" };
  }
}

/**
 * Every folder a workspace listing implies, sorted by path with the workspace root (`""`) first:
 * each listed file's containing folders, each listed empty directory and its own containing folders,
 * each checked-out submodule and its own containing folders, and the root itself. The listing
 * carries no folder list of its own (a directory exists there only as a prefix of something listed,
 * plus `emptyDirectories` and `submodulePaths`, which hold nothing to be a prefix of), which is
 * exactly the set of places the Files tree shows a folder row for, and so exactly the set of
 * destinations a move can name. A submodule needs its own input alongside `emptyDirectories`
 * because a submodule checkout that lists no file of its own (`pathTree.ts`'s `buildPathTree` seeds
 * it the same way) is otherwise invisible to this function: it names no path in `paths` and isn't
 * one of `emptyDirectories` either, so without this it (and any ancestor no other folder reveals)
 * would be missing from the picker.
 */
export function workspaceFolderPaths(
  paths: readonly string[],
  emptyDirectories: readonly string[],
  submodulePaths: readonly string[],
): string[] {
  const folders = new Set<string>([""]);
  for (const path of paths) addAncestors(path, folders);
  for (const directory of [...emptyDirectories, ...submodulePaths]) {
    folders.add(directory);
    addAncestors(directory, folders);
  }
  return [...folders].sort();
}

function addAncestors(path: string, into: Set<string>): void {
  for (let index = path.indexOf("/"); index !== -1; index = path.indexOf("/", index + 1)) {
    into.add(path.slice(0, index));
  }
}

/** The title line: "Move <name> to…", with the name in the tree's own monospace (see app.css). */
function moveTitle(name: string): DocumentFragment {
  const frag = document.createDocumentFragment();
  frag.appendChild(document.createTextNode("Move "));
  const nameEl = document.createElement("span");
  nameEl.className = "name";
  nameEl.textContent = name;
  frag.appendChild(nameEl);
  frag.appendChild(document.createTextNode(" to…"));
  return frag;
}

function labelFor(folder: string): string {
  return folder === "" ? ROOT_LABEL : folder;
}

function dirname(path: string): string {
  const idx = path.lastIndexOf("/");
  return idx === -1 ? "" : path.slice(0, idx);
}

function basename(path: string): string {
  const idx = path.lastIndexOf("/");
  return idx === -1 ? path : path.slice(idx + 1);
}
