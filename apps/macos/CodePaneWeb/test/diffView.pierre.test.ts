import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { registerCustomCSSVariableTheme } from "@pierre/diffs";
import type { ContextMenu, ContextMenuRequest } from "../src/app/contextMenu";
import { DiffView } from "../src/app/diffView";
import type { DiffCommentHooks } from "../src/app/diffView";
import type { DiffFileEntry } from "../src/bridge/types";

registerCustomCSSVariableTheme("spaces", {}, true);

const PATCH = `diff --git a/src/example.txt b/src/example.txt
index 1111111..2222222 100644
--- a/src/example.ts
+++ b/src/example.ts
@@ -1,1 +1,1 @@
-const value = oldValue;
+const value = newValue;
`;

const TWO_LINE_PATCH = `diff --git a/src/example.txt b/src/example.txt
index 1111111..2222222 100644
--- a/src/example.txt
+++ b/src/example.txt
@@ -1,2 +1,2 @@
-const value = oldValue;
+const value = newValue;
-const other = oldValue;
+const other = newValue;
`;

/** Old side 1..4 = alpha, beta, gamma, delta; new side 1..3 = alpha, delta, epsilon. Old and new
 *  line numbers diverge from line 2 on, so a right-click's mapped editor line proves which side of
 *  the rendered row it resolved. */
const DIVERGING_PATCH = `diff --git a/src/example.txt b/src/example.txt
index 1111111..2222222 100644
--- a/src/example.txt
+++ b/src/example.txt
@@ -1,4 +1,3 @@
 alpha
-beta
-gamma
 delta
+epsilon
`;

interface RecordingContextMenu extends ContextMenu {
  readonly requests: ContextMenuRequest[];
}

function recordingMenu(): RecordingContextMenu {
  const requests: ContextMenuRequest[] = [];
  let open = false;
  return {
    requests,
    show: (request) => {
      requests.push(request);
      open = true;
    },
    hide: () => {
      open = false;
    },
    isOpen: () => open,
  };
}

class NoopResizeObserver {
  observe(): void {}
  unobserve(): void {}
  disconnect(): void {}
}

class AlwaysVisibleIntersectionObserver {
  constructor(private readonly callback: IntersectionObserverCallback) {}
  observe(element: Element): void {
    this.callback([{ isIntersecting: true, target: element } as IntersectionObserverEntry], this as unknown as IntersectionObserver);
  }
  unobserve(): void {}
  disconnect(): void {}
}

function hooks(onRequestEdit: (path: string) => void, onRequestNewComment: DiffCommentHooks["onRequestNewComment"] = () => {}): DiffCommentHooks {
  return {
    renderCard: () => document.createElement("div"),
    onRequestNewComment,
    onRequestEdit,
  };
}

function file(): DiffFileEntry {
  return { path: "src/example.txt", status: "modified", patch: PATCH, isBinary: false, patchState: "ready" };
}

function divergingFile(): DiffFileEntry {
  return { path: "src/example.txt", status: "modified", patch: DIVERGING_PATCH, isBinary: false, patchState: "ready" };
}

function twoLineFile(): DiffFileEntry {
  return { path: "src/example.txt", status: "modified", patch: TWO_LINE_PATCH, isBinary: false, patchState: "ready" };
}

function queryOpenShadowRoots(root: ParentNode, selector: string): HTMLElement[] {
  const matches = [...root.querySelectorAll<HTMLElement>(selector)];
  for (const element of root.querySelectorAll<HTMLElement>("*")) {
    if (element.shadowRoot !== null) matches.push(...queryOpenShadowRoots(element.shadowRoot, selector));
  }
  return matches;
}

describe("DiffView with the real Pierre renderer", () => {
  let menu: RecordingContextMenu;

  beforeEach(() => {
    menu = recordingMenu();
    vi.stubGlobal("ResizeObserver", NoopResizeObserver);
    vi.stubGlobal("IntersectionObserver", AlwaysVisibleIntersectionObserver);
    vi.stubGlobal("CSSStyleSheet", class {
      replaceSync(): void {}
    });
    vi.stubGlobal("matchMedia", () => ({
      matches: false,
      media: "",
      onchange: null,
      addListener: () => {},
      removeListener: () => {},
      addEventListener: () => {},
      removeEventListener: () => {},
      dispatchEvent: () => false,
    }));
    vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(() => ({
      x: 0,
      y: 0,
      width: 800,
      height: 600,
      top: 0,
      right: 800,
      bottom: 600,
      left: 0,
      toJSON: () => ({}),
    } as DOMRect));
    vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockReturnValue({
      measureText: () => ({ width: 8 }),
    } as unknown as CanvasRenderingContext2D);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("starts editing only when Pierre reports a new-side line click", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const onRequestEdit = vi.fn();
    const view = new DiffView(container, "split", hooks(onRequestEdit), menu);

    view.setFiles([file()], false);
    await vi.waitFor(() => expect(container.querySelector("diffs-container")?.shadowRoot?.querySelector("pre")?.children.length).toBeGreaterThan(0));

    const fileContainer = container.querySelector("diffs-container");
    expect(fileContainer?.shadowRoot).toBeDefined();
    const shadowRoot = fileContainer!.shadowRoot!;
    const newLine = shadowRoot.querySelector<HTMLElement>('[data-line-type="change-addition"]');
    const oldLine = shadowRoot.querySelector<HTMLElement>('[data-line-type="change-deletion"]');
    expect(newLine).not.toBeNull();
    expect(oldLine).not.toBeNull();

    newLine!.dispatchEvent(new MouseEvent("click", { bubbles: true, composed: true }));
    expect(onRequestEdit).toHaveBeenCalledWith("src/example.txt");

    onRequestEdit.mockClear();
    oldLine!.dispatchEvent(new MouseEvent("click", { bubbles: true, composed: true }));
    expect(onRequestEdit).not.toHaveBeenCalled();

    container.remove();
  });

  it("keeps Pierre's diff renderer and highlights while editing its complete right-side document", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const view = new DiffView(container, "split", hooks(() => {}), menu);

    view.setFiles([file()], false);
    await vi.waitFor(() => expect(container.querySelector("diffs-container")?.shadowRoot?.querySelector("pre")?.children.length).toBeGreaterThan(0));
    view.beginEdit("src/example.txt", "const value = newValue;\n");

    await vi.waitFor(() => {
      const editor = queryOpenShadowRoots(container, '[role="textbox"]')[0];
      expect(editor?.id).toBe("code-pane-diff-edit-input");
      const rendered = container.querySelector("diffs-container")!.shadowRoot!;
      expect(rendered.querySelector('[data-line-type="change-deletion"]')).not.toBeNull();
      expect(rendered.querySelector('[data-line-type="change-addition"]')).not.toBeNull();
    });
    container.remove();
  });

  it("returns to the read-only header when the inline edit ends", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const view = new DiffView(container, "split", hooks(() => {}), menu);

    view.setFiles([file()], false);
    await vi.waitFor(() => expect(container.querySelector("diffs-container")?.shadowRoot?.querySelector("pre")?.children.length).toBeGreaterThan(0));
    view.beginEdit("src/example.txt", "const value = newValue;\n");
    await vi.waitFor(() => expect(queryOpenShadowRoots(container, "#code-pane-diff-edit-cancel")).toHaveLength(1));

    view.endEdit("src/example.txt");
    await vi.waitFor(() => {
      expect(queryOpenShadowRoots(container, "#code-pane-diff-edit-input")).toHaveLength(0);
      expect(queryOpenShadowRoots(container, "#code-pane-diff-edit-cancel")).toHaveLength(0);
      expect(queryOpenShadowRoots(container, "#code-pane-diff-edit-save")).toHaveLength(0);
    });

    view.beginEdit("src/example.txt", "const value = newValue;\n");
    await vi.waitFor(() => expect(queryOpenShadowRoots(container, "#code-pane-diff-edit-input")).toHaveLength(1));
    view.setEditConflict("src/example.txt", { kind: "changed", diskContent: "const value = diskValue;\n" });
    await vi.waitFor(() => expect(queryOpenShadowRoots(container, "#code-pane-diff-edit-input")).toHaveLength(0));
    // Pierre completes the read-only renderer asynchronously; a delayed post-render must not
    // restore the Spaces-owned identifier to a reused contenteditable.
    await new Promise((resolve) => setTimeout(resolve, 75));
    expect(queryOpenShadowRoots(container, "#code-pane-diff-edit-input")).toHaveLength(0);

    container.remove();
  });

  it("mounts the comment utility during the first render and routes a hovered line click", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const onRequestNewComment = vi.fn();
    const view = new DiffView(container, "split", hooks(() => {}, onRequestNewComment), menu);

    view.setFiles([file()], false);
    await vi.waitFor(() => expect(container.querySelector("diffs-container")?.shadowRoot?.querySelector("pre")?.children.length).toBeGreaterThan(0));
    const shadowRoot = container.querySelector("diffs-container")!.shadowRoot!;
    const newLine = shadowRoot.querySelector<HTMLElement>('[data-line-type="change-addition"]')!;
    const pointerMove = new Event("pointermove", { bubbles: true, composed: true });
    Object.defineProperty(pointerMove, "pointerType", { value: "mouse" });
    newLine.dispatchEvent(pointerMove);
    await vi.waitFor(() => expect(queryOpenShadowRoots(container, '[data-utility-button]')[0]?.id).toBe("code-pane-add-comment-src%2Fexample.txt"));
    const button = queryOpenShadowRoots(container, '[data-utility-button]')[0] as HTMLButtonElement;
    const pointerDown = new Event("pointerdown", { bubbles: true, composed: true });
    Object.assign(pointerDown, { pointerId: 1, pointerType: "mouse", button: 0 });
    button.dispatchEvent(pointerDown);
    const pointerUp = new Event("pointerup", { bubbles: true, composed: true });
    Object.assign(pointerUp, { pointerId: 1, pointerType: "mouse", button: 0 });
    document.dispatchEvent(pointerUp);

    expect(onRequestNewComment).toHaveBeenCalledWith({
      filePath: "src/example.txt",
      side: "new",
      lineNumber: 1,
      lineText: "const value = newValue;",
    });
    container.remove();
  });

  it("hides the native comment utility while the file is being edited", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const view = new DiffView(container, "split", hooks(() => {}), menu);

    view.setFiles([file()], false);
    expect(view.beginEdit("src/example.txt", "const value = newValue;\n")).toBe(true);
    await vi.waitFor(() => expect(queryOpenShadowRoots(container, "#code-pane-diff-edit-input")).toHaveLength(1));

    const editingRoots = queryOpenShadowRoots(container, "[data-code-pane-editing]");
    expect(editingRoots).toHaveLength(1);
    const unsafeStyle = queryOpenShadowRoots(container, "style[data-unsafe-css]")[0];
    expect(unsafeStyle?.textContent).toContain(":host([data-code-pane-editing]) [data-utility-button]");
    container.remove();
  });

  it("resolves the hovered line after restoring a focused line", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const onRequestNewComment = vi.fn();
    const view = new DiffView(container, "split", hooks(() => {}, onRequestNewComment), menu);

    view.setFiles([twoLineFile()], false);
    await vi.waitFor(() => {
      const shadowRoot = container.querySelector("diffs-container")?.shadowRoot;
      expect(shadowRoot?.querySelectorAll('[data-line-type="change-addition"]').length).toBeGreaterThanOrEqual(2);
    });
    view.restorePosition(null, null, null, "src/example.txt", 1, "new");
    const shadowRoot = container.querySelector("diffs-container")!.shadowRoot!;
    const lines = [...shadowRoot.querySelectorAll<HTMLElement>('[data-line-type="change-addition"]')]
      .filter((line) => line.dataset.line === "2");
    expect(lines.length).toBeGreaterThan(0);
    const pointerMove = new Event("pointermove", { bubbles: true, composed: true });
    Object.defineProperty(pointerMove, "pointerType", { value: "mouse" });
    lines[0]!.dispatchEvent(pointerMove);
    const button = queryOpenShadowRoots(container, '[data-utility-button]')[0] as HTMLButtonElement;
    const pointerDown = new Event("pointerdown", { bubbles: true, composed: true });
    Object.assign(pointerDown, { pointerId: 1, pointerType: "mouse", button: 0 });
    button.dispatchEvent(pointerDown);
    const pointerUp = new Event("pointerup", { bubbles: true, composed: true });
    Object.assign(pointerUp, { pointerId: 1, pointerType: "mouse", button: 0 });
    document.dispatchEvent(pointerUp);

    expect(onRequestNewComment).toHaveBeenCalledWith(expect.objectContaining({ lineNumber: 2 }));
    container.remove();
  });

  it("resolves an old-side right-click to the kept line the editor opens on", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const onRequestOpenInEditor = vi.fn();
    const view = new DiffView(container, "split", { ...hooks(() => {}), onRequestOpenInEditor }, menu);

    view.setFiles([divergingFile()], false);
    await vi.waitFor(() => expect(container.querySelector("diffs-container")?.shadowRoot?.querySelector("pre")?.children.length).toBeGreaterThan(0));
    const shadowRoot = container.querySelector("diffs-container")!.shadowRoot!;
    const removed = [...shadowRoot.querySelectorAll<HTMLElement>('[data-line-type="change-deletion"]')].find(
      (line) => line.dataset.line === "3",
    );
    expect(removed).toBeDefined();

    const event = new MouseEvent("contextmenu", { bubbles: true, composed: true, cancelable: true });
    removed!.dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
    // Old line 3 ("gamma") is deleted, so the editor lands on the next kept line, new line 2.
    expect(menu.requests.at(-1)?.header).toBe("example.txt:2");
    menu.requests.at(-1)!.items[0]!.onSelect();
    expect(onRequestOpenInEditor).toHaveBeenCalledWith("src/example.txt", 2);

    container.remove();
  });

  it("opens the menu from a right-click on a line number in the gutter, on either side and in either layout", async () => {
    for (const [layout, selector, header] of [
      ["split", '[data-deletions] [data-gutter] [data-column-number="3"]', "example.txt:2"],
      ["unified", '[data-gutter] [data-line-type="change-addition"][data-column-number="3"]', "example.txt:3"],
    ] as const) {
      const container = document.createElement("div");
      document.body.appendChild(container);
      const onRequestOpenInEditor = vi.fn();
      const view = new DiffView(container, layout, { ...hooks(() => {}), onRequestOpenInEditor }, menu);

      view.setFiles([divergingFile()], false);
      await vi.waitFor(() => expect(container.querySelector("diffs-container")?.shadowRoot?.querySelector("pre")?.children.length).toBeGreaterThan(0));
      const shadowRoot = container.querySelector("diffs-container")!.shadowRoot!;
      const cell = shadowRoot.querySelector<HTMLElement>(selector);
      expect(cell, `${layout} gutter cell`).not.toBeNull();
      // The number itself, not the stamped content row, is what the pointer is over.
      expect(cell!.closest("[data-line]")).toBeNull();

      const event = new MouseEvent("contextmenu", { bubbles: true, composed: true, cancelable: true });
      cell!.querySelector("[data-line-number-content]")!.dispatchEvent(event);

      expect(event.defaultPrevented, layout).toBe(true);
      expect(menu.requests.at(-1)?.header, layout).toBe(header);
      menu.requests.at(-1)!.items[0]!.onSelect();
      expect(onRequestOpenInEditor).toHaveBeenCalledWith("src/example.txt", Number(header.split(":")[1]));

      container.remove();
    }
  });

  it("resolves a new-side right-click to that same line", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const onRequestOpenInEditor = vi.fn();
    const view = new DiffView(container, "split", { ...hooks(() => {}), onRequestOpenInEditor }, menu);

    view.setFiles([divergingFile()], false);
    await vi.waitFor(() => expect(container.querySelector("diffs-container")?.shadowRoot?.querySelector("pre")?.children.length).toBeGreaterThan(0));
    const shadowRoot = container.querySelector("diffs-container")!.shadowRoot!;
    const added = [...shadowRoot.querySelectorAll<HTMLElement>('[data-line-type="change-addition"]')].find(
      (line) => line.dataset.line === "3",
    );
    expect(added).toBeDefined();

    const event = new MouseEvent("contextmenu", { bubbles: true, composed: true, cancelable: true });
    added!.dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
    expect(menu.requests.at(-1)?.header).toBe("example.txt:3");
    menu.requests.at(-1)!.items[0]!.onSelect();
    expect(onRequestOpenInEditor).toHaveBeenCalledWith("src/example.txt", 3);

    container.remove();
  });

  function shadowRootOf(container: HTMLElement): ShadowRoot {
    return container.querySelector("diffs-container")!.shadowRoot!;
  }

  it("closes an open right-click menu when the diff it was mapped from is replaced", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const view = new DiffView(container, "split", hooks(() => {}), menu);

    view.setFiles([divergingFile()], false);
    await vi.waitFor(() => expect(container.querySelector("diffs-container")?.shadowRoot?.querySelector("pre")?.children.length).toBeGreaterThan(0));
    const shadowRoot = container.querySelector("diffs-container")!.shadowRoot!;
    const added = [...shadowRoot.querySelectorAll<HTMLElement>('[data-line-type="change-addition"]')].find(
      (line) => line.dataset.line === "3",
    );
    added!.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, composed: true, cancelable: true }));
    expect(menu.isOpen()).toBe(true);

    view.setFiles([twoLineFile()], true); // a signature refresh replaced the diff
    expect(menu.isOpen()).toBe(false);

    added!.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, composed: true, cancelable: true }));
    view.setLoading(); // a scope switch
    expect(menu.isOpen()).toBe(false);

    view.setFiles([divergingFile()], false);
    await vi.waitFor(() => expect(shadowRootOf(container).querySelector("pre")?.children.length).toBeGreaterThan(0));
    const readded = [...shadowRootOf(container).querySelectorAll<HTMLElement>('[data-line-type="change-addition"]')].find(
      (line) => line.dataset.line === "3",
    );
    readded!.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, composed: true, cancelable: true }));
    expect(menu.isOpen()).toBe(true);
    view.setError("Unable to load this workspace's diff."); // a failed refresh
    expect(menu.isOpen()).toBe(false);

    container.remove();
  });

  it("leaves the native menu alone on the rows of the file being edited inline", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const onRequestOpenInEditor = vi.fn();
    const view = new DiffView(container, "split", { ...hooks(() => {}), onRequestOpenInEditor }, menu);

    view.setFiles([divergingFile()], false);
    await vi.waitFor(() => expect(container.querySelector("diffs-container")?.shadowRoot?.querySelector("pre")?.children.length).toBeGreaterThan(0));
    view.beginEdit("src/example.txt", "alpha\ndelta\nepsilon\n");
    await vi.waitFor(() => expect(queryOpenShadowRoots(container, '[role="textbox"]')[0]?.id).toBe("code-pane-diff-edit-input"));

    const shadowRoot = container.querySelector("diffs-container")!.shadowRoot!;
    const added = [...shadowRoot.querySelectorAll<HTMLElement>('[data-line-type="change-addition"]')].find(
      (line) => line.dataset.line === "3",
    );
    expect(added).toBeDefined();
    const event = new MouseEvent("contextmenu", { bubbles: true, composed: true, cancelable: true });
    added!.dispatchEvent(event);

    expect(event.defaultPrevented).toBe(false); // WebKit's Paste/Undo menu stays
    expect(menu.requests).toHaveLength(0);

    // The edit's conflict view compares disk against the buffer; its rows are not the diff's rows.
    view.setEditConflict("src/example.txt", { kind: "changed", diskContent: "alpha\ndelta\nzeta\n" });
    await vi.waitFor(() => {
      const rows = queryOpenShadowRoots(container, "[data-diff-path]");
      expect(rows.length).toBeGreaterThan(0);
      const conflictEvent = new MouseEvent("contextmenu", { bubbles: true, composed: true, cancelable: true });
      rows[0]!.dispatchEvent(conflictEvent);
      expect(conflictEvent.defaultPrevented).toBe(false);
    });
    expect(menu.requests).toHaveLength(0);
    expect(onRequestOpenInEditor).not.toHaveBeenCalled();

    container.remove();
  });

  it("does not expose a native gutter utility for a binary placeholder", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const view = new DiffView(container, "split", hooks(() => {}), menu);

    view.setFiles([{ ...file(), isBinary: true, patch: undefined }], false);
    await vi.waitFor(() => expect(container.querySelector("diffs-container")?.shadowRoot?.querySelector("pre")?.children.length).toBeGreaterThan(0));

    const line = queryOpenShadowRoots(container, "[data-line]")[0];
    const pointerMove = new Event("pointermove", { bubbles: true, composed: true });
    Object.defineProperty(pointerMove, "pointerType", { value: "mouse" });
    line?.dispatchEvent(pointerMove);
    const utility = queryOpenShadowRoots(container, "[data-utility-button]");
    expect(utility).toHaveLength(1);
    expect(utility[0]?.closest("[data-file]")).not.toBeNull();
    const unsafeStyle = queryOpenShadowRoots(container, "style[data-unsafe-css]")[0];
    expect(unsafeStyle?.textContent).toContain("[data-file] [data-utility-button]");
    container.remove();
  });
});
