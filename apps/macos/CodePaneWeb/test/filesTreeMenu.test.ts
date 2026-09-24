import { beforeEach, describe, expect, it, vi } from "vitest";
import { ContextMenu, ContextMenuRequest } from "../src/app/contextMenu";
import { FilesTreeActions, FilesTreeCallbacks, FilesTreeListing, renderFilesTree } from "../src/app/filesTree";
import { FolderPicker } from "../src/app/folderPicker";

// jsdom has no scrollIntoView implementation; setSelected calls it on the newly-highlighted row.
beforeEach(() => {
  Element.prototype.scrollIntoView = vi.fn();
});

/** Records every `contextMenu.show()` request instead of rendering a real floating menu; a test
 *  reads `menu.calls` to assert on the header/items a right-click produced, and calls an item's own
 *  `onSelect()` directly to simulate picking it (matching how `contextMenu.ts`'s real `activate()`
 *  invokes it). Open/closed is tracked for real, since `show` and `hide` are what the tree drives. */
function makeContextMenu(): ContextMenu & { calls: ContextMenuRequest[] } {
  const calls: ContextMenuRequest[] = [];
  let open = false;
  return {
    calls,
    show: (request) => {
      calls.push(request);
      open = true;
    },
    hide: vi.fn(() => {
      open = false;
    }),
    isOpen: () => open,
  };
}

function makeActions(overrides: Partial<FilesTreeActions> = {}): FilesTreeActions {
  return {
    createFile: vi.fn().mockResolvedValue(undefined),
    createFolder: vi.fn().mockResolvedValue(undefined),
    move: vi.fn().mockResolvedValue(undefined),
    remove: vi.fn().mockResolvedValue(undefined),
    openInSystemViewer: vi.fn().mockResolvedValue(undefined),
    isUnopenable: () => false,
    ...overrides,
  };
}

function makeCallbacks(overrides: Partial<FilesTreeCallbacks> = {}): FilesTreeCallbacks {
  return { onSelect: vi.fn(), onMutated: vi.fn(), ...overrides };
}

/**
 * A fixed listing exercising every row kind a test below needs:
 *  - "src": a directory row WITH children ("a.ts" and the nested "src/nested" directory).
 *  - "src/a.ts": a file row nested one level, whose containing directory is "src".
 *  - "src/nested" / "src/nested/b.ts": a second directory-with-children, one level deeper.
 *  - "root.ts": a root-level file row (containing directory is the workspace root, "").
 *  - "empty": a childless directory row, from `emptyDirectories`.
 */
const LISTING = {
  paths: ["src/a.ts", "src/nested/b.ts", "root.ts"],
  submodules: [],
  emptyDirectories: ["empty"],
};

function setup(options?: {
  actions?: Partial<FilesTreeActions>;
  callbacks?: Partial<FilesTreeCallbacks>;
  /** Defaults to a workspace whose files are on this Mac; set false for a workspace on another device. */
  canOpenInSystemViewer?: boolean;
}): {
  container: HTMLElement;
  menu: ContextMenu & { calls: ContextMenuRequest[] };
  /** Where the real Move to… folder picker mounts its overlay; the pane, in the app. */
  pickerHost: HTMLElement;
  actions: FilesTreeActions;
  callbacks: FilesTreeCallbacks;
  /** Re-renders the same container with a new listing, exactly as the host does when workspace file
   *  membership changes on the device. */
  refresh: (listing?: FilesTreeListing) => void;
} {
  const container = document.createElement("div");
  document.body.appendChild(container);
  const pickerHost = document.createElement("div");
  document.body.appendChild(pickerHost);
  const menu = makeContextMenu();
  // The real picker, not a stub: Move to… is now entirely a pick from this overlay, so the tests
  // below drive it exactly as the user does.
  const folderPicker = new FolderPicker(pickerHost);
  const actions = makeActions(options?.actions);
  const callbacks = makeCallbacks(options?.callbacks);
  const render = (listing: FilesTreeListing): void => {
    renderFilesTree({
      container,
      listing,
      selectedPath: undefined,
      callbacks,
      contextMenu: menu,
      folderPicker,
      actions,
      canOpenInSystemViewer: options?.canOpenInSystemViewer ?? true,
    });
  };
  render(LISTING);
  return { container, menu, pickerHost, actions, callbacks, refresh: (listing) => render(listing ?? LISTING) };
}

/** True while the folder picker's overlay is showing. */
function pickerIsOpen(host: HTMLElement): boolean {
  return (host.querySelector(".quick-open-backdrop") as HTMLElement).style.display !== "none";
}

function pickerTitle(host: HTMLElement): string {
  return (host.querySelector(".folder-picker .title") as HTMLElement).textContent ?? "";
}

function pickerInput(host: HTMLElement): HTMLInputElement {
  return host.querySelector(".folder-picker input") as HTMLInputElement;
}

/** The destination rows, in the order they are listed. */
function pickerRows(host: HTMLElement): HTMLElement[] {
  return [...host.querySelectorAll<HTMLElement>(".folder-picker .list .row")];
}

function pickerRowTexts(host: HTMLElement): (string | null)[] {
  return pickerRows(host).map((row) => row.querySelector(".path")?.textContent ?? null);
}

/** The row Return would act on. */
function pickerSelectedText(host: HTMLElement): string | null {
  return host.querySelector(".folder-picker .list .row.sel .path")?.textContent ?? null;
}

function typeInPicker(host: HTMLElement, text: string): void {
  const input = pickerInput(host);
  input.value = text;
  input.dispatchEvent(new Event("input"));
}

function pressInPicker(host: HTMLElement, key: string): void {
  pickerInput(host).dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
}

function fileRow(container: HTMLElement, path: string): HTMLElement {
  // Expand every ancestor directory first; rows are lazily materialized (see filesTree.ts's doc
  // comment), so a nested file's row doesn't exist in the DOM until its directory has been opened.
  for (const dirrow of [...container.querySelectorAll<HTMLElement>(".dirrow")]) dirrow.click();
  return container.querySelector(`.row[data-path="${path}"]`) as HTMLElement;
}

function dirRow(container: HTMLElement, label: string): HTMLElement {
  return [...container.querySelectorAll<HTMLElement>(".dirrow")].find(
    (row) => row.querySelector(".dirlabel")?.textContent === label,
  )!;
}

function rightClick(el: HTMLElement, x = 10, y = 20): void {
  el.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: x, clientY: y }));
}

function labelsOf(request: ContextMenuRequest): string[] {
  return request.items.map((item) => item.label);
}

function itemNamed(request: ContextMenuRequest, label: string): () => void {
  return request.items.find((item) => item.label === label)!.onSelect;
}

describe("filesTree pointer menu: opening", () => {
  it("opens on a file row with the file's path as header and the row item set", () => {
    const { container, menu } = setup();
    rightClick(fileRow(container, "root.ts"));

    expect(menu.calls).toHaveLength(1);
    expect(menu.calls[0]!.header).toBe("root.ts");
    expect(labelsOf(menu.calls[0]!)).toEqual(["New file", "New folder", "Rename", "Move to…", "Delete"]);
  });

  it("opens on a directory row with the directory's path as header and the same row item set, minus Open in system viewer", () => {
    const { container, menu } = setup();
    rightClick(dirRow(container, "src"));

    expect(menu.calls).toHaveLength(1);
    expect(menu.calls[0]!.header).toBe("src");
    expect(labelsOf(menu.calls[0]!)).toEqual(["New file", "New folder", "Rename", "Move to…", "Delete"]);
  });

  it("opens on the tree's empty background with the workspace root as header and only the New items", () => {
    const { container, menu } = setup();
    rightClick(container);

    expect(menu.calls).toHaveLength(1);
    expect(menu.calls[0]!.header).toBe("/");
    expect(labelsOf(menu.calls[0]!)).toEqual(["New file", "New folder"]);
  });

  it("does not also let WebKit's native menu appear (preventDefault on every row and the background)", () => {
    const { container } = setup();
    const fileEvent = new MouseEvent("contextmenu", { bubbles: true, cancelable: true });
    fileRow(container, "root.ts").dispatchEvent(fileEvent);
    expect(fileEvent.defaultPrevented).toBe(true);

    const bgEvent = new MouseEvent("contextmenu", { bubbles: true, cancelable: true });
    container.dispatchEvent(bgEvent);
    expect(bgEvent.defaultPrevented).toBe(true);
  });

  it("shows Open in system viewer only for a file the Editor reports as unopenable", () => {
    const { container: openableContainer, menu: openableMenu } = setup({ actions: { isUnopenable: () => false } });
    rightClick(fileRow(openableContainer, "root.ts"));
    expect(labelsOf(openableMenu.calls[0]!)).not.toContain("Open in system viewer");

    const { container: unopenableContainer, menu: unopenableMenu } = setup({ actions: { isUnopenable: () => true } });
    rightClick(fileRow(unopenableContainer, "root.ts"));
    expect(labelsOf(unopenableMenu.calls[0]!)).toContain("Open in system viewer");
  });

  it("never offers Open in system viewer on a directory row, even when isUnopenable is unconditionally true", () => {
    const { container, menu } = setup({ actions: { isUnopenable: () => true } });
    rightClick(dirRow(container, "src"));
    expect(labelsOf(menu.calls[0]!)).not.toContain("Open in system viewer");
  });

  // Handing a file to macOS needs a path on this Mac, so a workspace on another device has nothing to
  // offer here; the item is left out rather than offered and then refused by the host.
  it("never offers Open in system viewer in a workspace whose files are on another device", () => {
    const { container, menu } = setup({ actions: { isUnopenable: () => true }, canOpenInSystemViewer: false });
    rightClick(fileRow(container, "root.ts"));
    expect(labelsOf(menu.calls[0]!)).not.toContain("Open in system viewer");
  });
});

describe("filesTree pointer menu: New file / New folder", () => {
  it("inserts a draft row inside the target folder, and Enter calls createFile with the joined path, then onSelect and onMutated in that order", async () => {
    const { container, menu, actions, callbacks } = setup();
    rightClick(dirRow(container, "src"));
    itemNamed(menu.calls[0]!, "New file")();

    const draft = container.querySelector(".row.draft") as HTMLElement;
    expect(draft).not.toBeNull();
    const field = draft.querySelector("input.inline-name") as HTMLInputElement;
    field.value = "new.ts";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    await vi.waitFor(() => expect(actions.createFile).toHaveBeenCalledWith("src/new.ts"));
    expect(callbacks.onSelect).toHaveBeenCalledWith("src/new.ts");
    expect(callbacks.onMutated).toHaveBeenCalled();
    // In that order: both land on the daemon's one per-workspace serial queue, so a listing refetch
    // posted first would hold the open of the file the user is waiting to see behind it.
    const selectOrder = (callbacks.onSelect as ReturnType<typeof vi.fn>).mock.invocationCallOrder[0]!;
    const mutatedOrder = (callbacks.onMutated as ReturnType<typeof vi.fn>).mock.invocationCallOrder[0]!;
    expect(selectOrder).toBeLessThan(mutatedOrder);
  });

  it("New folder targets the workspace root from the background menu and does not select anything", async () => {
    const { container, menu, actions, callbacks } = setup();
    rightClick(container);
    itemNamed(menu.calls[0]!, "New folder")();

    const field = container.querySelector("input.inline-name") as HTMLInputElement;
    field.value = "docs";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    await vi.waitFor(() => expect(actions.createFolder).toHaveBeenCalledWith("docs"));
    expect(callbacks.onSelect).not.toHaveBeenCalled();
    expect(callbacks.onMutated).toHaveBeenCalled();
  });

  it("an empty name cancels with no call and removes the draft row", async () => {
    const { container, menu, actions } = setup();
    rightClick(container);
    itemNamed(menu.calls[0]!, "New file")();

    const field = container.querySelector("input.inline-name") as HTMLInputElement;
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    await vi.waitFor(() => expect(container.querySelector(".row.draft")).toBeNull());
    expect(actions.createFile).not.toHaveBeenCalled();
  });

  // A workspace path keeps the whitespace around a name, so the typed value reaches the daemon
  // verbatim: trimming would create the neighbouring "target" instead of the " target " asked for.
  it("creates a folder whose name carries surrounding whitespace exactly as typed", async () => {
    const { container, menu, actions } = setup();
    rightClick(dirRow(container, "src"));
    itemNamed(menu.calls[0]!, "New folder")();

    const field = container.querySelector("input.inline-name") as HTMLInputElement;
    field.value = " target ";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    await vi.waitFor(() => expect(actions.createFolder).toHaveBeenCalledWith("src/ target "));
  });

  // Whitespace alone is still a blank field: trimming is what recognizes that, and nothing else.
  it("a whitespace-only name cancels with no call and removes the draft row", async () => {
    const { container, menu, actions } = setup();
    rightClick(container);
    itemNamed(menu.calls[0]!, "New file")();

    const field = container.querySelector("input.inline-name") as HTMLInputElement;
    field.value = "   ";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    await vi.waitFor(() => expect(container.querySelector(".row.draft")).toBeNull());
    expect(actions.createFile).not.toHaveBeenCalled();
  });

  it("Escape cancels with no call and removes the draft row", () => {
    const { container, menu, actions } = setup();
    rightClick(container);
    itemNamed(menu.calls[0]!, "New file")();

    const field = container.querySelector("input.inline-name") as HTMLInputElement;
    field.value = "typed-then-abandoned.ts";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));

    expect(container.querySelector(".row.draft")).toBeNull();
    expect(actions.createFile).not.toHaveBeenCalled();
  });

  it("a rejected create shows the message under the row and leaves the field open", async () => {
    const createFile = vi.fn().mockRejectedValue(new Error("'new.ts' already exists."));
    const { container, menu } = setup({ actions: { createFile } });
    rightClick(container);
    itemNamed(menu.calls[0]!, "New file")();

    const field = container.querySelector("input.inline-name") as HTMLInputElement;
    field.value = "new.ts";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    await vi.waitFor(() => expect(container.querySelector(".inline-error")).not.toBeNull());
    expect(container.querySelector(".inline-error")?.textContent).toBe("'new.ts' already exists.");
    expect(container.querySelector(".row.draft")).not.toBeNull(); // still open
    expect((container.querySelector("input.inline-name") as HTMLInputElement).disabled).toBe(false);
  });

  // The daemon's resolver drops an empty path component rather than refusing it (`foo/` -> `foo`),
  // so a trailing slash sent as-is would create a path other than the one the tree goes on to open
  // and persist. Refused the same way an existing-path rejection is: inline error, field stays open.
  it("a trailing slash refuses with no call and leaves the field open", async () => {
    const { container, menu, actions } = setup();
    rightClick(container);
    itemNamed(menu.calls[0]!, "New file")();

    const field = container.querySelector("input.inline-name") as HTMLInputElement;
    field.value = "foo/";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    await vi.waitFor(() => expect(container.querySelector(".inline-error")).not.toBeNull());
    expect(actions.createFile).not.toHaveBeenCalled();
    expect(container.querySelector(".row.draft")).not.toBeNull(); // still editable
  });

  it("a repeated slash in a New folder name is refused with no call", async () => {
    const { container, menu, actions } = setup();
    rightClick(container);
    itemNamed(menu.calls[0]!, "New folder")();

    const field = container.querySelector("input.inline-name") as HTMLInputElement;
    field.value = "a//b";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    await vi.waitFor(() => expect(container.querySelector(".inline-error")).not.toBeNull());
    expect(actions.createFolder).not.toHaveBeenCalled();
  });

  it("a nested name with real directory segments still creates the file inside them", async () => {
    const { container, menu, actions, callbacks } = setup();
    rightClick(container);
    itemNamed(menu.calls[0]!, "New file")();

    const field = container.querySelector("input.inline-name") as HTMLInputElement;
    field.value = "a/b.ts";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    await vi.waitFor(() => expect(actions.createFile).toHaveBeenCalledWith("a/b.ts"));
    expect(callbacks.onSelect).toHaveBeenCalledWith("a/b.ts");
  });

  // A whitespace-edged name has no empty component (its edge characters are spaces, not slashes), so
  // the empty-component refusal leaves it untouched: only a literal "/" at either end is refused.
  it("a whitespace-edged name still creates the file exactly as typed", async () => {
    const { container, menu, actions } = setup();
    rightClick(container);
    itemNamed(menu.calls[0]!, "New file")();

    const field = container.querySelector("input.inline-name") as HTMLInputElement;
    field.value = " target ";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    await vi.waitFor(() => expect(actions.createFile).toHaveBeenCalledWith(" target "));
  });
});

describe("filesTree pointer menu: Rename", () => {
  it("commits the joined destination and calls onMutated", async () => {
    const { container, menu, actions, callbacks } = setup();
    const row = fileRow(container, "src/a.ts");
    rightClick(row);
    itemNamed(menu.calls[0]!, "Rename")();

    const field = row.querySelector("input.inline-name") as HTMLInputElement;
    expect(field.value).toBe("a.ts"); // seeded with the current basename
    field.value = "renamed.ts";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    await vi.waitFor(() => expect(actions.move).toHaveBeenCalledWith("src/a.ts", "src/renamed.ts"));
    expect(callbacks.onMutated).toHaveBeenCalled();
  });

  it("renaming to the same name makes no call", () => {
    const { container, menu, actions } = setup();
    const row = fileRow(container, "src/a.ts");
    rightClick(row);
    itemNamed(menu.calls[0]!, "Rename")();

    const field = row.querySelector("input.inline-name") as HTMLInputElement;
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    expect(actions.move).not.toHaveBeenCalled();
  });

  // A file whose own name carries leading whitespace seeds the field with that exact name, so
  // committing it untouched is still "unchanged": reading it as a rename to the trimmed spelling
  // would move a file the user only looked at.
  it("renaming a name with leading whitespace makes no call when the field is untouched", () => {
    const { container, menu, actions, refresh } = setup();
    refresh({ paths: [" spaced.txt"], submodules: [], emptyDirectories: [] });
    const row = fileRow(container, " spaced.txt");
    rightClick(row);
    itemNamed(menu.calls[0]!, "Rename")();

    const field = row.querySelector("input.inline-name") as HTMLInputElement;
    expect(field.value).toBe(" spaced.txt");
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    expect(actions.move).not.toHaveBeenCalled();
  });

  // The destination carries the typed spelling verbatim: a name may legitimately be whitespace-edged,
  // and trimming would rename the file to a different name than the one asked for.
  it("renames to a whitespace-edged name exactly as typed", async () => {
    const { container, menu, actions } = setup();
    const row = fileRow(container, "src/a.ts");
    rightClick(row);
    itemNamed(menu.calls[0]!, "Rename")();

    const field = row.querySelector("input.inline-name") as HTMLInputElement;
    field.value = " target ";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    await vi.waitFor(() => expect(actions.move).toHaveBeenCalledWith("src/a.ts", "src/ target "));
  });

  it("a whitespace-only name makes no call", () => {
    const { container, menu, actions } = setup();
    const row = fileRow(container, "src/a.ts");
    rightClick(row);
    itemNamed(menu.calls[0]!, "Rename")();

    const field = row.querySelector("input.inline-name") as HTMLInputElement;
    field.value = "   ";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    expect(actions.move).not.toHaveBeenCalled();
  });

  it("a trailing slash refuses the rename with no call", async () => {
    const { container, menu, actions } = setup();
    const row = fileRow(container, "src/a.ts");
    rightClick(row);
    itemNamed(menu.calls[0]!, "Rename")();

    const field = row.querySelector("input.inline-name") as HTMLInputElement;
    field.value = "x/";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    await vi.waitFor(() => expect(container.querySelector(".inline-error")).not.toBeNull());
    expect(actions.move).not.toHaveBeenCalled();
  });
});

describe("filesTree pointer menu: Move to…", () => {
  it("opens the folder picker over the pane, named for the item, listing every folder with the current one first and unpickable", () => {
    const { container, menu, pickerHost } = setup();
    const row = fileRow(container, "src/a.ts");
    rightClick(row);
    itemNamed(menu.calls[0]!, "Move to…")();

    expect(pickerIsOpen(pickerHost)).toBe(true);
    expect(pickerTitle(pickerHost)).toBe("Move a.ts to…");
    // The workspace root shows as "/", the same spelling the tree's background menu uses for it.
    expect(pickerRowTexts(pickerHost)).toEqual(["src", "/", "empty", "src/nested"]);

    const current = pickerRows(pickerHost)[0]!;
    expect(current.querySelector(".badge")?.textContent).toBe("current");
    expect(current.getAttribute("aria-disabled")).toBe("true");
    // The highlight starts below it: the folder the item already sits in is not a destination.
    expect(pickerSelectedText(pickerHost)).toBe("/");
  });

  it("lists a childless submodule checkout as a destination, since it is a folder in the workspace even though it reveals no file of its own", () => {
    const { container, menu, pickerHost, refresh } = setup();
    refresh({ ...LISTING, submodules: [{ path: "vendor/lib", commit: "abc1234" }] });
    rightClick(fileRow(container, "src/a.ts"));
    itemNamed(menu.calls[0]!, "Move to…")();

    expect(pickerRowTexts(pickerHost)).toEqual(["src", "/", "empty", "src/nested", "vendor", "vendor/lib"]);
  });

  it("leaves a folder being moved, and everything under it, out of its own destination list", () => {
    const { container, menu, pickerHost } = setup();
    rightClick(dirRow(container, "src"));
    itemNamed(menu.calls[0]!, "Move to…")();

    expect(pickerTitle(pickerHost)).toBe("Move src to…");
    expect(pickerRowTexts(pickerHost)).toEqual(["/", "empty"]);
  });

  it("fuzzy-filters the folders as the destination is typed", () => {
    const { container, menu, pickerHost } = setup();
    rightClick(fileRow(container, "src/a.ts"));
    itemNamed(menu.calls[0]!, "Move to…")();

    typeInPicker(pickerHost, "nest");

    expect(pickerRowTexts(pickerHost)).toEqual(["src/nested"]);
    expect(pickerRows(pickerHost)[0]!.querySelector("mark")?.textContent).toBe("nest");
  });

  it("moves the item into the chosen folder under its own name, and reloads the listing", async () => {
    let settleMove!: () => void;
    const move = vi.fn().mockReturnValue(
      new Promise<void>((resolve) => {
        settleMove = resolve;
      }),
    );
    const { container, menu, pickerHost, actions, callbacks } = setup({ actions: { move } });
    const row = fileRow(container, "src/a.ts");
    rightClick(row);
    itemNamed(menu.calls[0]!, "Move to…")();

    typeInPicker(pickerHost, "nest");
    pressInPicker(pickerHost, "Enter");

    expect(actions.move).toHaveBeenCalledWith("src/a.ts", "src/nested/a.ts");
    expect(pickerIsOpen(pickerHost)).toBe(false);
    // The row reads as busy for as long as the daemon takes, the way the inline field it replaced
    // disabled itself mid-commit.
    expect(row.className).toContain("in-flight");
    expect(row.getAttribute("aria-busy")).toBe("true");

    settleMove();
    await vi.waitFor(() => expect(callbacks.onMutated).toHaveBeenCalled());
    expect(row.className).not.toContain("in-flight");
  });

  it("moves to the workspace root under the bare name", async () => {
    const { container, menu, pickerHost, actions } = setup();
    rightClick(fileRow(container, "src/a.ts"));
    itemNamed(menu.calls[0]!, "Move to…")();

    // "/" is the root's own row; it also matches the separator inside a nested folder's path, so the
    // root is picked by its position rather than by being the only match.
    typeInPicker(pickerHost, "/");
    expect(pickerSelectedText(pickerHost)).toBe("/");
    pressInPicker(pickerHost, "Enter");

    await vi.waitFor(() => expect(actions.move).toHaveBeenCalledWith("src/a.ts", "a.ts"));
  });

  it("walks the list with the arrow keys, stepping over the current folder", async () => {
    const { container, menu, pickerHost, actions } = setup();
    rightClick(fileRow(container, "src/a.ts"));
    itemNamed(menu.calls[0]!, "Move to…")();

    pressInPicker(pickerHost, "ArrowDown");
    expect(pickerSelectedText(pickerHost)).toBe("empty");
    pressInPicker(pickerHost, "ArrowUp");
    expect(pickerSelectedText(pickerHost)).toBe("/");
    // Already at the topmost destination: Up cannot reach the current folder above it.
    pressInPicker(pickerHost, "ArrowUp");
    expect(pickerSelectedText(pickerHost)).toBe("/");

    pressInPicker(pickerHost, "Enter");

    await vi.waitFor(() => expect(actions.move).toHaveBeenCalledWith("src/a.ts", "a.ts"));
  });

  it("Escape closes the picker without moving anything and hands focus back to the row", () => {
    const { container, menu, pickerHost, actions } = setup();
    const row = fileRow(container, "src/a.ts");
    rightClick(row);
    itemNamed(menu.calls[0]!, "Move to…")();
    expect(document.activeElement).toBe(pickerInput(pickerHost));

    pressInPicker(pickerHost, "Escape");

    expect(pickerIsOpen(pickerHost)).toBe(false);
    expect(actions.move).not.toHaveBeenCalled();
    expect(document.activeElement).toBe(row);
  });

  it("shows a refused move under the row and reloads nothing", async () => {
    const move = vi.fn().mockRejectedValue(new Error("src/nested/a.ts already exists"));
    const { container, menu, pickerHost, callbacks } = setup({ actions: { move } });
    const row = fileRow(container, "src/a.ts");
    rightClick(row);
    itemNamed(menu.calls[0]!, "Move to…")();

    typeInPicker(pickerHost, "nest");
    pressInPicker(pickerHost, "Enter");

    await vi.waitFor(() =>
      expect(row.nextElementSibling?.textContent).toBe("src/nested/a.ts already exists"),
    );
    expect(row.nextElementSibling?.className).toBe("inline-error");
    expect(callbacks.onMutated).not.toHaveBeenCalled();
    expect(row.className).not.toContain("in-flight");
  });

  it("dismisses an open picker when a listing refresh replaces the rows it was opened over", () => {
    const { container, menu, pickerHost, refresh } = setup();
    rightClick(fileRow(container, "src/a.ts"));
    itemNamed(menu.calls[0]!, "Move to…")();
    expect(pickerIsOpen(pickerHost)).toBe(true);

    refresh();

    expect(pickerIsOpen(pickerHost)).toBe(false);
  });
});

describe("filesTree pointer menu: Delete", () => {
  it("on a file, asks for confirmation naming the path and only calls remove on confirm", async () => {
    const { container, menu, actions, callbacks } = setup();
    rightClick(fileRow(container, "root.ts"));
    itemNamed(menu.calls[0]!, "Delete")();

    expect(menu.calls).toHaveLength(2);
    expect(menu.calls[1]!.header).toBe("Delete root.ts?");
    expect(labelsOf(menu.calls[1]!)).toEqual(["Delete", "Cancel"]);
    expect(actions.remove).not.toHaveBeenCalled();

    itemNamed(menu.calls[1]!, "Delete")();
    await vi.waitFor(() => expect(actions.remove).toHaveBeenCalledWith("root.ts"));
    expect(callbacks.onMutated).toHaveBeenCalled();
  });

  it("on a file, Cancel never calls remove", () => {
    const { container, menu, actions } = setup();
    rightClick(fileRow(container, "root.ts"));
    itemNamed(menu.calls[0]!, "Delete")();
    itemNamed(menu.calls[1]!, "Cancel")();

    expect(actions.remove).not.toHaveBeenCalled();
  });

  // A folder row with no children is not evidence of an empty directory: its entries may all be
  // gitignored, or it may be a submodule checkout whose files this listing does not carry. The
  // delete is recursive either way, so it confirms like every other one.
  it("on a folder that renders no children, still asks for confirmation before removing anything", async () => {
    const { container, menu, actions } = setup();
    rightClick(dirRow(container, "empty"));
    itemNamed(menu.calls[0]!, "Delete")();

    expect(menu.calls).toHaveLength(2);
    expect(menu.calls[1]!.header).toBe("Delete empty?");
    expect(labelsOf(menu.calls[1]!)).toEqual(["Delete", "Cancel"]);
    expect(actions.remove).not.toHaveBeenCalled();

    itemNamed(menu.calls[1]!, "Delete")();
    await vi.waitFor(() => expect(actions.remove).toHaveBeenCalledWith("empty"));
  });

  it("on a folder with children, asks for confirmation first", () => {
    const { container, menu, actions } = setup();
    rightClick(dirRow(container, "src"));
    itemNamed(menu.calls[0]!, "Delete")();

    expect(menu.calls).toHaveLength(2);
    expect(menu.calls[1]!.header).toBe("Delete src?");
    expect(actions.remove).not.toHaveBeenCalled();
  });
});

describe("filesTree pointer menu: Open in system viewer", () => {
  it("calls the action and, on rejection, shows the message under the row", async () => {
    const openInSystemViewer = vi.fn().mockRejectedValue(new Error("Could not open this file."));
    const { container, menu } = setup({ actions: { isUnopenable: () => true, openInSystemViewer } });
    const row = fileRow(container, "root.ts");
    rightClick(row);
    itemNamed(menu.calls[0]!, "Open in system viewer")();

    expect(openInSystemViewer).toHaveBeenCalledWith("root.ts");
    await vi.waitFor(() => expect(row.nextElementSibling?.className).toBe("inline-error"));
    expect(row.nextElementSibling?.textContent).toBe("Could not open this file.");
  });
});

// The inline field lives INSIDE the row it edits, and that row keeps every listener it was built
// with (click/keydown to open or toggle, contextmenu to open the pointer menu). Without the field
// stopping propagation, typing in it would drive the row behind it.
describe("filesTree pointer menu: the open inline field owns its own events", () => {
  it("Space types into the field instead of being swallowed by the row's own key handler", () => {
    const { container, menu, callbacks } = setup();
    const row = fileRow(container, "src/a.ts");
    rightClick(row);
    itemNamed(menu.calls[0]!, "Rename")();

    const field = row.querySelector("input.inline-name") as HTMLInputElement;
    const space = new KeyboardEvent("keydown", { key: " ", bubbles: true, cancelable: true });
    field.dispatchEvent(space);

    expect(space.defaultPrevented).toBe(false); // the row's handler would have prevented the character
    expect(callbacks.onSelect).not.toHaveBeenCalled();
  });

  it("Enter commits the rename without also opening the file behind the field", async () => {
    const { container, menu, actions, callbacks } = setup();
    const row = fileRow(container, "src/a.ts");
    rightClick(row);
    itemNamed(menu.calls[0]!, "Rename")();

    const field = row.querySelector("input.inline-name") as HTMLInputElement;
    field.value = "renamed.ts";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    await vi.waitFor(() => expect(actions.move).toHaveBeenCalledWith("src/a.ts", "src/renamed.ts"));
    expect(callbacks.onSelect).not.toHaveBeenCalled();
  });

  it("Enter commits a directory rename without also toggling that directory open", async () => {
    const { container, menu, actions } = setup();
    const dirrow = dirRow(container, "src");
    expect(dirrow.getAttribute("aria-expanded")).toBe("false");
    rightClick(dirrow);
    itemNamed(menu.calls[0]!, "Rename")();

    const field = dirrow.querySelector("input.inline-name") as HTMLInputElement;
    field.value = "sources";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    await vi.waitFor(() => expect(actions.move).toHaveBeenCalledWith("src", "sources"));
    expect(dirrow.getAttribute("aria-expanded")).toBe("false");
  });

  it("a right-click on the field leaves the native input menu alone instead of opening the tree's menu", () => {
    const { container, menu } = setup();
    const row = fileRow(container, "src/a.ts");
    rightClick(row);
    itemNamed(menu.calls[0]!, "Rename")();

    const field = row.querySelector("input.inline-name") as HTMLInputElement;
    const event = new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 5, clientY: 5 });
    field.dispatchEvent(event);

    expect(menu.calls).toHaveLength(1); // still just the Rename menu this test opened
    expect(event.defaultPrevented).toBe(false); // WebKit's own field menu is what should appear
  });
});

/** Root-level file rows currently in the DOM, by path. */
function rootFilePaths(container: HTMLElement): string[] {
  return [...container.querySelectorAll<HTMLElement>(".row[data-path]")].map((row) => row.dataset.path!);
}

const LISTING_WITH_ADDED_FILE: FilesTreeListing = {
  paths: [...LISTING.paths, "added.ts"],
  submodules: [],
  emptyDirectories: LISTING.emptyDirectories,
};

// A listing refresh arrives whenever workspace file membership changes on the device, which includes
// changes nobody in this pane made. Rendering it replaces the container's whole contents, so an open
// field (and everything typed into it) would go with it.
describe("filesTree pointer menu: a listing refresh during an open inline field", () => {
  it("keeps the field and its draft, holding the refreshed listing back", () => {
    const { container, menu, refresh } = setup();
    rightClick(container);
    itemNamed(menu.calls[0]!, "New file")();

    const field = container.querySelector("input.inline-name") as HTMLInputElement;
    field.value = "half-typed.ts";
    refresh(LISTING_WITH_ADDED_FILE);

    expect(container.querySelector("input.inline-name")).toBe(field);
    expect(field.value).toBe("half-typed.ts");
    expect(rootFilePaths(container)).not.toContain("added.ts");
  });

  it("applies the held refresh once the field is cancelled", () => {
    const { container, menu, refresh } = setup();
    rightClick(container);
    itemNamed(menu.calls[0]!, "New file")();

    const field = container.querySelector("input.inline-name") as HTMLInputElement;
    field.value = "abandoned.ts";
    refresh(LISTING_WITH_ADDED_FILE);
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));

    expect(container.querySelector("input.inline-name")).toBeNull();
    expect(container.querySelector(".row.draft")).toBeNull();
    expect(rootFilePaths(container)).toContain("added.ts");
  });

  it("keeps a Rename field open across a refresh and applies the held listing when it closes", () => {
    const { container, menu, refresh } = setup();
    const row = fileRow(container, "root.ts");
    rightClick(row);
    itemNamed(menu.calls[0]!, "Rename")();

    const field = row.querySelector("input.inline-name") as HTMLInputElement;
    field.value = "renamed-but-not-committed.ts";
    refresh(LISTING_WITH_ADDED_FILE);
    expect(row.querySelector("input.inline-name")).toBe(field);
    expect(field.value).toBe("renamed-but-not-committed.ts");

    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    expect(rootFilePaths(container)).toContain("added.ts");
  });

  // Only the newest listing is worth keeping: the tree renders what the device last reported, not a
  // backlog of every refresh that arrived while the field was open.
  it("applies only the last of several held refreshes", () => {
    const { container, menu, refresh } = setup();
    rightClick(container);
    itemNamed(menu.calls[0]!, "New file")();

    const field = container.querySelector("input.inline-name") as HTMLInputElement;
    refresh(LISTING_WITH_ADDED_FILE);
    refresh({ paths: ["final.ts"], submodules: [], emptyDirectories: [] });
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));

    expect(rootFilePaths(container)).toEqual(["final.ts"]);
  });
});

// A row action reports under the row it was started from: the busy state while it runs, and a refusal
// when the device refuses it. A refresh that replaced the rows mid-action would take that row with it,
// leaving the move repeatable with no visible busy state and the refusal written into DOM nobody sees.
describe("filesTree pointer menu: a listing refresh during a pending row action", () => {
  /** Starts Move to… on the root-level "root.ts" row, into the "empty" folder, and returns the row. */
  function startMove(container: HTMLElement, menu: ContextMenu & { calls: ContextMenuRequest[] }, pickerHost: HTMLElement): HTMLElement {
    const row = fileRow(container, "root.ts");
    rightClick(row);
    itemNamed(menu.calls[0]!, "Move to…")();
    typeInPicker(pickerHost, "empty");
    pressInPicker(pickerHost, "Enter");
    return row;
  }

  it("holds the refresh while a move is in flight and applies it once the move settles", async () => {
    let settleMove!: () => void;
    const move = vi.fn().mockReturnValue(
      new Promise<void>((resolve) => {
        settleMove = resolve;
      }),
    );
    const { container, menu, pickerHost, callbacks, refresh } = setup({ actions: { move } });
    const row = startMove(container, menu, pickerHost);

    refresh(LISTING_WITH_ADDED_FILE);

    expect(rootFilePaths(container)).not.toContain("added.ts");
    expect(row.getAttribute("aria-busy")).toBe("true");
    expect(container.contains(row)).toBe(true);

    settleMove();
    await vi.waitFor(() => expect(callbacks.onMutated).toHaveBeenCalled());
    await vi.waitFor(() => expect(rootFilePaths(container)).toContain("added.ts"));
  });

  it("renders a refused move under the row, and applies the held refresh with that refusal kept", async () => {
    const move = vi.fn().mockRejectedValue(new Error("empty/root.ts already exists"));
    const { container, menu, pickerHost, refresh } = setup({ actions: { move } });
    startMove(container, menu, pickerHost);

    refresh(LISTING_WITH_ADDED_FILE);

    await vi.waitFor(() => expect(container.querySelector(".inline-error")).not.toBeNull());
    expect(rootFilePaths(container)).toContain("added.ts");
    const error = container.querySelector(".inline-error")!;
    expect(error.textContent).toBe("empty/root.ts already exists");
    expect((error.previousElementSibling as HTMLElement).dataset.path).toBe("root.ts");
  });

  it("holds the refresh while a delete is in flight and applies it once the delete settles", async () => {
    let settleRemove!: () => void;
    const remove = vi.fn().mockReturnValue(
      new Promise<void>((resolve) => {
        settleRemove = resolve;
      }),
    );
    const { container, menu, callbacks, refresh } = setup({ actions: { remove } });
    rightClick(fileRow(container, "root.ts"));
    itemNamed(menu.calls[0]!, "Delete")();
    itemNamed(menu.calls[1]!, "Delete")();

    refresh(LISTING_WITH_ADDED_FILE);

    expect(rootFilePaths(container)).not.toContain("added.ts");

    settleRemove();
    await vi.waitFor(() => expect(callbacks.onMutated).toHaveBeenCalled());
    await vi.waitFor(() => expect(rootFilePaths(container)).toContain("added.ts"));
  });

  it("renders a refused delete under the row, and applies the held refresh with that refusal kept", async () => {
    const remove = vi.fn().mockRejectedValue(new Error("Use git to remove a submodule checkout."));
    const { container, menu, refresh } = setup({ actions: { remove } });
    rightClick(fileRow(container, "root.ts"));
    itemNamed(menu.calls[0]!, "Delete")();
    itemNamed(menu.calls[1]!, "Delete")();

    refresh(LISTING_WITH_ADDED_FILE);

    await vi.waitFor(() => expect(container.querySelector(".inline-error")).not.toBeNull());
    expect(rootFilePaths(container)).toContain("added.ts");
    const error = container.querySelector(".inline-error")!;
    expect(error.textContent).toBe("Use git to remove a submodule checkout.");
    expect((error.previousElementSibling as HTMLElement).dataset.path).toBe("root.ts");
  });
});

// The menu's items close over the rows of the render they were opened from; a refresh discards those
// rows, so a menu left open would act on something the user is no longer pointing at.
describe("filesTree pointer menu: a listing refresh while the menu is open", () => {
  it("dismisses the row menu", () => {
    const { container, menu, refresh } = setup();
    rightClick(fileRow(container, "root.ts"));
    expect(menu.isOpen()).toBe(true);

    refresh(LISTING_WITH_ADDED_FILE);

    expect(menu.hide).toHaveBeenCalled();
    expect(menu.isOpen()).toBe(false);
  });

  it("dismisses a pending Delete confirmation", () => {
    const { container, menu, actions, refresh } = setup();
    rightClick(fileRow(container, "root.ts"));
    itemNamed(menu.calls[0]!, "Delete")();
    expect(menu.calls[1]!.header).toBe("Delete root.ts?");
    expect(menu.isOpen()).toBe(true);

    refresh(LISTING_WITH_ADDED_FILE);

    expect(menu.isOpen()).toBe(false);
    expect(actions.remove).not.toHaveBeenCalled();
  });

  it("dismisses the background menu", () => {
    const { container, menu, refresh } = setup();
    rightClick(container);
    expect(menu.isOpen()).toBe(true);

    refresh();

    expect(menu.isOpen()).toBe(false);
  });
});

// A row has no text worth copying by selection (Copy path on the row's own menu carries that), so
// rows are `user-select: none` (app.css) and the tree's own menu opens on every right-click, even one
// WebKit has already turned into a text selection on the row's name before the `contextmenu` event
// fires (real WebKit behavior on macOS; jsdom doesn't do this on its own, so these tests force the
// selection to stand in for it).
describe("filesTree pointer menu: a right-click that lands on selected row text", () => {
  /** Selects `node`'s contents for real (jsdom implements Selection and Range), matching what
   *  WebKit's own right-click word-select produces on a row's name before `contextmenu` fires. */
  function selectContents(node: Node): void {
    const range = document.createRange();
    range.selectNodeContents(node);
    const selection = window.getSelection()!;
    selection.removeAllRanges();
    selection.addRange(range);
  }

  beforeEach(() => window.getSelection()?.removeAllRanges());

  it("still opens the tree's menu on a file row with its name selected", () => {
    const { container, menu } = setup();
    const row = fileRow(container, "root.ts");
    selectContents(row.querySelector(".fn")!);

    const event = new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 20 });
    row.dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
    expect(menu.calls).toHaveLength(1);
  });

  it("still opens the tree's menu on a directory row with its name selected", () => {
    const { container, menu } = setup();
    const dirrow = dirRow(container, "src");
    selectContents(dirrow.querySelector(".dirlabel")!);

    const event = new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 20 });
    dirrow.dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
    expect(menu.calls).toHaveLength(1);
  });
});
