import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { registerCustomCSSVariableTheme } from "@pierre/diffs";
import { EditorView } from "../src/app/editorView";
import type { FileSignatureEvent, SpacesBridge, WorkspaceFileReadResult } from "../src/bridge/types";

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
    workspaceRevisionFileRead: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceFileWrite: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceFileList: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceRefList: vi.fn().mockRejectedValue(new Error("not used")),
    subscribeDiffSignature: vi.fn(() => () => {}),
    subscribeFileListSignature: vi.fn(() => () => {}),
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

/** The Pierre editor instance driving the open file, reached through the view's private CodeView
 *  because EditorView deliberately exposes no editor handle of its own. */
function pierreEditor(view: EditorView, path: string): {
  setSelections(selections: Array<{
    start: { line: number; character: number };
    end: { line: number; character: number };
    direction: "forward" | "backward" | "none";
  }>): void;
  getViewState(): { selections?: Array<{ start: { line: number }; end: { line: number }; direction: number }> };
  getText(): string;
} {
  const editor = (view as unknown as {
    codeView?: {
      getEditor(id: string): {
        setSelections(selections: Array<{
          start: { line: number; character: number };
          end: { line: number; character: number };
          direction: "forward" | "backward" | "none";
        }>): void;
        getViewState(): { selections?: Array<{ start: { line: number }; end: { line: number }; direction: number }> };
        getText(): string;
      } | undefined;
    };
  }).codeView?.getEditor(path);
  expect(editor).toBeDefined();
  return editor!;
}

/** The buffer EditorView would write on Save. */
function latestContent(view: EditorView): string | undefined {
  return (view as unknown as { latestContent?: string }).latestContent;
}

/** Whether the buffer holds unsaved edits, which is what gates Save and the discard prompts. */
function isDirty(view: EditorView): boolean {
  return (view as unknown as { dirty: boolean }).dirty;
}

/** A bridge that serves `reads` in order and hands back the file-signature listener EditorView
 *  registers, so a test can push a real "this file changed on disk" event. */
function makeReloadBridge(reads: WorkspaceFileReadResult[]): {
  bridge: SpacesBridge;
  fireFileSignature: (event: FileSignatureEvent) => void;
} {
  let index = 0;
  let listener: ((event: FileSignatureEvent) => void) | undefined;
  const bridge: SpacesBridge = {
    ...makeBridge(reads[0]!),
    workspaceFileRead: vi.fn(() => Promise.resolve(reads[Math.min(index++, reads.length - 1)]!)),
    subscribeFileSignature: vi.fn((_path: string, next: (event: FileSignatureEvent) => void) => {
      listener = next;
      return () => {
        listener = undefined;
      };
    }),
  };
  return { bridge, fireFileSignature: (event) => listener?.(event) };
}

/** Dispatches a paste of `text` over the editor's whole document. */
function pasteOverWholeDocument(editorElement: HTMLElement, text: string): void {
  const paste = new Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(paste, "clipboardData", {
    value: { getData: (type: string) => (type === "text" ? text : undefined) },
  });
  editorElement.dispatchEvent(paste);
}

/** The text of each rendered line, read straight off the editor surface's child divs: the DOM the
 *  user actually sees, which is what a stale render leaves behind. */
function renderedLines(editorElement: HTMLElement): string[] {
  return [...editorElement.children].map((line) => line.textContent ?? "");
}

/** Lets Pierre finish the render pass that follows an edit. A stale-render regression paints the
 *  new text and then reverts the line divs on the next frame, so the rendered text is only worth
 *  asserting once those frames have run. */
async function settleRender(frames = 3): Promise<void> {
  for (let i = 0; i < frames; i += 1) await new Promise((resolve) => requestAnimationFrame(() => resolve(undefined)));
}

/** Opens `path` and resolves once Pierre's editable surface carries its automation identifier. */
async function openAndWaitForEditor(container: HTMLElement, view: EditorView, path: string): Promise<HTMLElement> {
  view.open(path);
  await vi.waitFor(() => {
    const editor = queryOpenShadowRoots(container, '[role="textbox"][aria-multiline="true"]')[0];
    expect(editor?.id).toBe("code-pane-editor-input");
  });
  return queryOpenShadowRoots(container, '[role="textbox"][aria-multiline="true"]')[0]!;
}

const SIX_LINE_NOTES = "state line 001\nstate line 002\nstate line 003\nstate line 004\nstate line 005\nstate line 006\n";
const RELOADED_NOTES = "reloaded line 1\nreloaded line 2\n";

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

    const editor = pierreEditor(view, "src/example.txt");

    // Pierre normalizes a backward range so start <= end but keeps direction, making the active
    // caret the start endpoint for backward selections and the end endpoint for forward ones.
    editor.setSelections([{ start: { line: 0, character: 0 }, end: { line: 2, character: 0 }, direction: "forward" }]);
    expect(view.focusedLineNumber()).toBe(3);
    editor.setSelections([{ start: { line: 0, character: 0 }, end: { line: 2, character: 0 }, direction: "backward" }]);
    expect(view.focusedLineNumber()).toBe(1);

    const line = queryOpenShadowRoots(container, "[data-line]").find((candidate) => candidate.dataset.line === "1");
    expect(line).not.toBeUndefined();
    view.restorePosition(null, 4);
    await vi.waitFor(() => expect(view.focusedLineNumber()).toBe(4));
    expect(editor.getViewState().selections?.at(-1)?.end.line).toBe(3);

    container.remove();
  });

  it("repaints every line when a paste replaces a selection spanning the whole file", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const view = new EditorView(container, makeBridge({ content: SIX_LINE_NOTES, sha256: "sha-1", size: SIX_LINE_NOTES.length }));
    const editorElement = await openAndWaitForEditor(container, view, "notes.txt");
    const editor = pierreEditor(view, "notes.txt");

    editor.setSelections([{ start: { line: 0, character: 0 }, end: { line: 6, character: 0 }, direction: "forward" }]);
    pasteOverWholeDocument(editorElement, "PASTED\n");

    await vi.waitFor(() => expect(latestContent(view)).toBe("PASTED\n"));
    await settleRender();
    expect(renderedLines(editorElement)).toEqual(["PASTED", ""]);

    container.remove();
  });

  it("repaints the joined line when Backspace at the start of a line joins it with the one above", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const view = new EditorView(container, makeBridge({ content: SIX_LINE_NOTES, sha256: "sha-1", size: SIX_LINE_NOTES.length }));
    const editorElement = await openAndWaitForEditor(container, view, "notes.txt");
    const editor = pierreEditor(view, "notes.txt");
    const lineCountBefore = renderedLines(editorElement).length;

    editor.setSelections([{ start: { line: 1, character: 0 }, end: { line: 1, character: 0 }, direction: "none" }]);
    const backspace = new Event("beforeinput", { bubbles: true, cancelable: true });
    Object.defineProperty(backspace, "inputType", { value: "deleteContentBackward" });
    Object.defineProperty(backspace, "data", { value: null });
    editorElement.dispatchEvent(backspace);

    const joined = "state line 001state line 002\nstate line 003\nstate line 004\nstate line 005\nstate line 006\n";
    await vi.waitFor(() => expect(latestContent(view)).toBe(joined));
    await settleRender();
    expect(renderedLines(editorElement)[0]).toBe("state line 001state line 002");
    expect(renderedLines(editorElement).length).toBe(lineCountBefore - 1);

    container.remove();
  });
it("adopts a file that changed on disk into the rendered document and leaves the buffer clean", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const { bridge, fireFileSignature } = makeReloadBridge([
      { content: SIX_LINE_NOTES, sha256: "sha-1", size: SIX_LINE_NOTES.length },
      { content: RELOADED_NOTES, sha256: "sha-2", size: RELOADED_NOTES.length },
    ]);
    const view = new EditorView(container, bridge);
    await openAndWaitForEditor(container, view, "notes.txt");

    fireFileSignature({ path: "notes.txt", sha256: "sha-2", missing: false });

    await vi.waitFor(() => {
      const surface = queryOpenShadowRoots(container, '[role="textbox"][aria-multiline="true"]')[0];
      expect(surface === undefined ? [] : renderedLines(surface)).toEqual(["reloaded line 1", "reloaded line 2", ""]);
    });
    // Pierre's own document, not just the painted lines: an edit made after the reload is written
    // from this text, so a stale document here would save the pre-reload file over the new one.
    expect(pierreEditor(view, "notes.txt").getText()).toBe(RELOADED_NOTES);
    expect(latestContent(view)).toBe(RELOADED_NOTES);
    // Adopting disk is not an edit: Save stays disabled and nothing counts as unsaved.
    expect(isDirty(view)).toBe(false);
    expect(container.querySelector<HTMLButtonElement>("button.primary")?.disabled).toBe(true);

    // The very next real edit still registers, so the adoption suppresses one event and no more.
    const editorElement = queryOpenShadowRoots(container, '[role="textbox"][aria-multiline="true"]')[0]!;
    pierreEditor(view, "notes.txt").setSelections([
      { start: { line: 0, character: 0 }, end: { line: 2, character: 0 }, direction: "forward" },
    ]);
    pasteOverWholeDocument(editorElement, "TYPED\n");
    await vi.waitFor(() => expect(latestContent(view)).toBe("TYPED\n"));
    expect(isDirty(view)).toBe(true);

    container.remove();
  });
});
