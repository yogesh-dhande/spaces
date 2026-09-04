import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { registerCustomCSSVariableTheme } from "@pierre/diffs";
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
  beforeEach(() => {
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
    const view = new DiffView(container, "split", hooks(onRequestEdit));

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
    const view = new DiffView(container, "split", hooks(() => {}));

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
    const view = new DiffView(container, "split", hooks(() => {}));

    view.setFiles([file()], false);
    await vi.waitFor(() => expect(container.querySelector("diffs-container")?.shadowRoot?.querySelector("pre")?.children.length).toBeGreaterThan(0));
    view.beginEdit("src/example.txt", "const value = newValue;\n");
    await vi.waitFor(() => expect(queryOpenShadowRoots(container, "#code-pane-diff-edit-input")).toHaveLength(1));

    view.endEdit("src/example.txt");
    await vi.waitFor(() => {
      expect(queryOpenShadowRoots(container, "#code-pane-diff-edit-input")).toHaveLength(0);
      expect(queryOpenShadowRoots(container, ".diff-edit-header")).toHaveLength(0);
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
    const view = new DiffView(container, "split", hooks(() => {}, onRequestNewComment));

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
    const view = new DiffView(container, "split", hooks(() => {}));

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
    const view = new DiffView(container, "split", hooks(() => {}, onRequestNewComment));

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

  it("does not expose a native gutter utility for a binary placeholder", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const view = new DiffView(container, "split", hooks(() => {}));

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
