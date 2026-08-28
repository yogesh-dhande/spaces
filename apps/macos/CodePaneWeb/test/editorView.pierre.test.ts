import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { registerCustomCSSVariableTheme } from "@pierre/diffs";
import { EditorView } from "../src/app/editorView";
import type { SpacesBridge, WorkspaceFileReadResult } from "../src/bridge/types";

registerCustomCSSVariableTheme("spaces", {}, true);

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

function makeBridge(result: WorkspaceFileReadResult): SpacesBridge {
  return {
    workspaceDiffManifestChunk: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceDiffFileChunk: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceDiffFileChunkCancel: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceDiffManifestRelease: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceFileRead: vi.fn().mockResolvedValue(result),
    workspaceFileWrite: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceFileList: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceRefList: vi.fn().mockRejectedValue(new Error("not used")),
    subscribeDiffSignature: vi.fn(() => () => {}),
    subscribeFileSignature: vi.fn(() => () => {}),
    notifyWorkspaceStateChanged: vi.fn(),
    notifyRenderMetric: vi.fn(),
    reviewCommentList: vi.fn().mockRejectedValue(new Error("not used")),
    reviewCommentUpsert: vi.fn().mockRejectedValue(new Error("not used")),
    reviewCommentDelete: vi.fn().mockRejectedValue(new Error("not used")),
    reviewCommentsSend: vi.fn().mockRejectedValue(new Error("not used")),
    startWorkspaceCommand: vi.fn().mockRejectedValue(new Error("not used")),
    resumeWorkspaceCommandTracking: vi.fn().mockRejectedValue(new Error("not used")),
  };
}

function queryOpenShadowRoots(root: ParentNode, selector: string): HTMLElement[] {
  const matches = [...root.querySelectorAll<HTMLElement>(selector)];
  for (const element of root.querySelectorAll<HTMLElement>("*")) {
    if (element.shadowRoot !== null) matches.push(...queryOpenShadowRoots(element.shadowRoot, selector));
  }
  return matches;
}

describe("EditorView with the real Pierre renderer", () => {
  beforeEach(() => {
    Element.prototype.scrollIntoView = function scrollIntoView(): void {};
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

  it("reads Pierre's canonical caret endpoint and restores focus in the shadow-root editor", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const view = new EditorView(container, makeBridge({ content: "line 1\nline 2\nline 3\nline 4\n", sha256: "sha-1", size: 28 }));

    view.open("src/example.txt");

    await vi.waitFor(() => {
      const editor = queryOpenShadowRoots(container, '[role="textbox"][aria-multiline="true"]')[0];
      expect(editor?.id).toBe("code-pane-editor-input");
    });
    expect(view.visibleLine()).toBe(1);

    const editor = (view as unknown as {
      codeView?: {
        getEditor(path: string): {
          setSelections(selections: Array<{
            start: { line: number; character: number };
            end: { line: number; character: number };
            direction: "forward" | "backward";
          }>): void;
          getState(): { selections?: Array<{ start: { line: number }; end: { line: number }; direction: number }> };
        } | undefined;
      };
    }).codeView?.getEditor("src/example.txt");
    expect(editor).toBeDefined();

    // Pierre normalizes a backward range so start <= end but keeps direction, making the active
    // caret the start endpoint for backward selections and the end endpoint for forward ones.
    editor!.setSelections([{ start: { line: 0, character: 0 }, end: { line: 2, character: 0 }, direction: "forward" }]);
    expect(view.focusedLineNumber()).toBe(3);
    editor!.setSelections([{ start: { line: 0, character: 0 }, end: { line: 2, character: 0 }, direction: "backward" }]);
    expect(view.focusedLineNumber()).toBe(1);

    const line = queryOpenShadowRoots(container, "[data-line]").find((candidate) => candidate.dataset.line === "1");
    expect(line).not.toBeUndefined();
    view.restorePosition(null, 4);
    await vi.waitFor(() => expect(view.focusedLineNumber()).toBe(4));
    expect(editor!.getState().selections?.at(-1)?.end.line).toBe(3);

    container.remove();
  });
});
