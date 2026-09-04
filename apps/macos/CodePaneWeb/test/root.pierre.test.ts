import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { registerCustomCSSVariableTheme } from "@pierre/diffs";
import { mountRoot } from "../src/app/root";
import type { CodePaneInitPayload, DiffFileEntry } from "../src/bridge/types";

/**
 * The pane's keyboard shortcuts against the real `@pierre/diffs` renderer rather than the stubbed
 * one every other `root.test.ts` case uses. Pierre's own editor installs a keydown handler on its
 * contenteditable that calls `preventDefault()` on Escape (it collapses the selection), so a
 * shortcut listener that runs after it can never see an Escape typed inside the editor: only a
 * real Pierre editor proves the pane still closes the session.
 */

registerCustomCSSVariableTheme("spaces", {}, true);

const PATCH = `diff --git a/src/example.txt b/src/example.txt
index 1111111..2222222 100644
--- a/src/example.txt
+++ b/src/example.txt
@@ -1,1 +1,1 @@
-const value = oldValue;
+const value = newValue;
`;

const FILE: DiffFileEntry = { path: "src/example.txt", status: "modified", patch: PATCH, isBinary: false };

const INIT_PAYLOAD: CodePaneInitPayload = {
  workspaceId: "w1",
  workspaceName: "Test workspace",
  workspaceState: {
    mode: "diff",
    scope: { kind: "uncommitted" },
    diffLayout: "unified",
    editorSidebarMode: "files",
    editorRecentPaths: [],
    selectedAgentSessionId: null,
    pendingAgentLaunch: null,
    fileTreeExpandedPaths: [],
    diffSelectedPath: null,
    diffTreeSelectedPath: null,
    fileTreeSelectedPath: null,
    diffScrollLine: null,
    diffScrollSide: null,
    diffFocusedPath: null,
    diffFocusedLine: null,
    diffFocusedSide: null,
    editorScrollLine: null,
    editorFocusedLine: null,
    editorState: null,
    diffEditorState: null,
    pendingReviewComments: null,
  },
  theme: "dark",
  baseBranch: "main",
  agents: [],
};

const hoisted = vi.hoisted(() => ({
  workspaceFileRead: vi.fn(),
  workspaceFileWrite: vi.fn(),
  notifyWorkspaceStateChanged: vi.fn(),
}));

vi.mock("../src/bridge", () => ({
  createBridge: async () => ({
    notifyReady: () => {
      queueMicrotask(() => {
        window.dispatchEvent(new CustomEvent("spaces:init", { detail: INIT_PAYLOAD }));
      });
    },
    workspaceDiffManifestChunk: vi.fn(async (_scope: unknown, request: { manifestID?: string; fileIndex: number }) => ({
      manifestID: request.manifestID ?? "manifest-1",
      scopeSignature: "sig-1",
      files: [{ path: FILE.path, status: FILE.status }],
      nextFileIndex: undefined,
    })),
    workspaceDiffFileChunk: vi.fn(async () => ({
      scopeSignature: "sig-1",
      file: FILE,
      patchBase64Data: btoa(PATCH),
    })),
    workspaceDiffFileChunkCancel: vi.fn().mockResolvedValue(undefined),
    workspaceDiffManifestRelease: vi.fn().mockResolvedValue(undefined),
    workspaceFileRead: hoisted.workspaceFileRead,
    workspaceRevisionFileRead: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceRefList: vi.fn().mockResolvedValue({ branches: ["main"], branchesTruncated: false, commits: [], commitsTruncated: false }),
    workspaceFileWrite: hoisted.workspaceFileWrite,
    workspaceFileList: vi.fn().mockRejectedValue(new Error("not used")),
    subscribeDiffSignature: vi.fn(() => () => {}),
    subscribeFileListSignature: vi.fn(() => () => {}),
    subscribeFileSignature: vi.fn(() => () => {}),
    notifyWorkspaceStateChanged: hoisted.notifyWorkspaceStateChanged,
    notifyRenderMetric: vi.fn(),
    notifyEditsFlushed: vi.fn(),
    reviewCommentList: vi.fn().mockResolvedValue([]),
    reviewCommentUpsert: vi.fn().mockRejectedValue(new Error("not used")),
    reviewCommentDelete: vi.fn().mockRejectedValue(new Error("not used")),
    reviewCommentsSend: vi.fn().mockRejectedValue(new Error("not used")),
    startWorkspaceCommand: vi.fn().mockRejectedValue(new Error("not used")),
    resumeWorkspaceCommandTracking: vi.fn().mockRejectedValue(new Error("not used")),
  }),
}));

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

function queryOpenShadowRoots(root: ParentNode, selector: string): HTMLElement[] {
  const matches = [...root.querySelectorAll<HTMLElement>(selector)];
  for (const element of root.querySelectorAll<HTMLElement>("*")) {
    if (element.shadowRoot !== null) matches.push(...queryOpenShadowRoots(element.shadowRoot, selector));
  }
  return matches;
}

describe("mountRoot's editing shortcuts against the real Pierre editor", () => {
  let container: HTMLElement;
  const mounted: Array<{ dispose(): void }> = [];

  beforeEach(() => {
    hoisted.workspaceFileRead.mockReset();
    hoisted.workspaceFileWrite.mockReset();
    hoisted.notifyWorkspaceStateChanged.mockClear();
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
    Element.prototype.scrollIntoView = function scrollIntoView(): void {};
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
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  afterEach(() => {
    for (const handle of mounted.splice(0)) handle.dispose();
    container.remove();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("ends the inline session on Escape typed inside Pierre's editor, which swallows the key itself", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "const value = newValue;\n", sha256: "sha-before", size: 24 });
    mounted.push(await mountRoot(container));

    const addedLine = await vi.waitFor(() => {
      const line = container.querySelector("diffs-container")?.shadowRoot?.querySelector<HTMLElement>('[data-line-type="change-addition"]');
      expect(line).toBeInstanceOf(HTMLElement);
      return line!;
    });
    addedLine.dispatchEvent(new MouseEvent("click", { bubbles: true, composed: true }));

    const editor = await vi.waitFor(() => {
      const found = queryOpenShadowRoots(container, "#code-pane-diff-edit-input")[0];
      expect(found).toBeInstanceOf(HTMLElement);
      return found!;
    });
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({ path: FILE.path });

    editor.focus();
    // Pierre's own handler calls `preventDefault()` on this event before it bubbles out of the
    // editor, so a bubble-phase pane listener sees it already claimed and does nothing.
    editor.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, composed: true, cancelable: true }));

    await vi.waitFor(() =>
      expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toBeNull(),
    );
  });
});
