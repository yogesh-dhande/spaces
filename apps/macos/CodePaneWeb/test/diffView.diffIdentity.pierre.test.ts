import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { registerCustomCSSVariableTheme } from "@pierre/diffs";
import { createContextMenu } from "../src/app/contextMenu";
import type { ContextMenu } from "../src/app/contextMenu";
import { DiffView } from "../src/app/diffView";
import type { DiffCommentHooks } from "../src/app/diffView";
import type { DiffFileEntry } from "../src/bridge/types";

registerCustomCSSVariableTheme("spaces", {}, true);

const PATCH = `diff --git a/src/highlighted.ts b/src/highlighted.ts
index 1111111..2222222 100644
--- a/src/highlighted.ts
+++ b/src/highlighted.ts
@@ -1,1 +1,1 @@
-const value = oldValue;
+const value = alphaValue;
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

function hooks(): DiffCommentHooks {
  return { renderCard: () => document.createElement("div"), onRequestNewComment: () => {}, onRequestEdit: () => {} };
}

/** Neither test here right-clicks a rendered line, so the menu `DiffView` is handed only has to
 *  exist (see diffView.pierre.test.ts for context-menu-interaction coverage). */
function testContextMenu(): ContextMenu {
  return createContextMenu(document.createElement("div"));
}

const REFRESHED_PATCH = `diff --git a/src/highlighted.ts b/src/highlighted.ts
index 1111111..3333333 100644
--- a/src/highlighted.ts
+++ b/src/highlighted.ts
@@ -1,1 +1,1 @@
-const value = oldValue;
+const value = betaValue;
`;

function file(): DiffFileEntry {
  return { path: "src/highlighted.ts", status: "modified", patch: PATCH, isBinary: false, patchState: "ready" };
}

/** The same path after a live refresh replaced its patch: one changed addition line. */
function refreshedFile(): DiffFileEntry {
  return { path: "src/highlighted.ts", status: "modified", patch: REFRESHED_PATCH, isBinary: false, patchState: "ready" };
}

function queryOpenShadowRoots(root: ParentNode, selector: string): HTMLElement[] {
  const matches = [...root.querySelectorAll<HTMLElement>(selector)];
  for (const element of root.querySelectorAll<HTMLElement>("*")) {
    if (element.shadowRoot !== null) matches.push(...queryOpenShadowRoots(element.shadowRoot, selector));
  }
  return matches;
}

/** Every text node the pane renders, light DOM and open shadow roots alike. Pierre reports a failed
 *  render inside the file's own shadow root, so a DOM assertion has to descend into it. */
function allShadowText(root: ParentNode): string {
  let text = (root as Element | DocumentFragment).textContent ?? "";
  for (const element of root.querySelectorAll<HTMLElement>("*")) {
    if (element.shadowRoot !== null) text += allShadowText(element.shadowRoot);
  }
  return text;
}

/** Lets Pierre finish the render passes that follow an item update. */
async function settleRender(frames = 3): Promise<void> {
  for (let i = 0; i < frames; i += 1) await new Promise((resolve) => requestAnimationFrame(() => resolve(undefined)));
}

/**
 * Regression coverage for the diff-object identity contract, against the real Pierre renderer.
 *
 * `@pierre/diffs` decides what changed by `cacheKey` (`utils/areDiffTargetsEqual` compares keys and
 * only falls back to object identity for keyless diffs) but checks the object it rendered against
 * the object it prepared by identity (`VirtualizedFileDiff.finalizeRender`). Handing it a re-parsed
 * `FileDiffMetadata` under an unchanged key therefore makes `FileDiff.render` keep the previously
 * rendered object while the finalizer sees a different one, and it throws "VirtualizedFileDiff.
 * render: rendered a different diff than its prepared layout". Pierre catches that inside its own
 * render, so the app sees it as a `console.error` plus a file whose lines stop painting.
 *
 * The throw needs a render whose prepared diff comes from `DiffHunksRenderer.getReadyRenderResult`,
 * which here means an asynchronous Shiki highlight landing after the item was updated. That is why
 * this test updates the item without waiting for the first render to settle, and why it lives in
 * its own file: the window exists only while the file's language is not yet attached to the shared
 * highlighter, and each test file gets its own module registry (and so its own highlighter).
 */
describe("DiffView diff object identity", () => {
  beforeEach(() => {
    // jsdom has no layout, so Pierre's caret reveal would throw on the element it scrolls to.
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

  it("does not report a mismatched render when a file is re-supplied with the same patch", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const errors: string[] = [];
    vi.spyOn(console, "error").mockImplementation((...args: unknown[]) => {
      errors.push(args.map((arg) => String(arg)).join(" "));
    });
    const view = new DiffView(container, "split", hooks(), testContextMenu());

    view.setFiles([file()], false);
    // Deliberately no settle: the item update has to land while the first render's highlight is
    // still in flight, which is the window the app hits when an annotation refresh (deleting a
    // comment draft, say) updates an item shortly after it first renders.
    view.updateFile(file());

    // Either the highlight lands and paints highlighted tokens, or Pierre reports the mismatch
    // instead of painting them. Waiting on that choice keeps the assertions below from passing
    // vacuously before Pierre has done the render that used to throw.
    await vi.waitFor(() => {
      expect(errors.length > 0 || queryOpenShadowRoots(container, "span[style]").length > 0).toBe(true);
    });
    expect(errors).toEqual([]);
    expect(queryOpenShadowRoots(container, "span[style]").length).toBeGreaterThan(0);
    expect(allShadowText(container)).toContain("const value = alphaValue;");
    expect(allShadowText(container)).not.toContain("prepared layout");

    container.remove();
  });

  // The other half of the same contract: a live refresh replaces a path's patch text, and Pierre
  // decides what changed from the `cacheKey` alone. Content supplied under a key it has already
  // rendered is content it never adopts, so the pane would keep painting the superseded patch.
  it("paints the replacement patch when a live refresh changes a file's text", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const errors: string[] = [];
    vi.spyOn(console, "error").mockImplementation((...args: unknown[]) => {
      errors.push(args.map((arg) => String(arg)).join(" "));
    });
    const view = new DiffView(container, "split", hooks(), testContextMenu());

    view.setFiles([file()], false);
    await vi.waitFor(() => expect(allShadowText(container)).toContain("alphaValue"));
    await settleRender();

    view.updateFile(refreshedFile());

    await vi.waitFor(() => expect(allShadowText(container)).toContain("betaValue"));
    await settleRender();
    expect(allShadowText(container)).not.toContain("alphaValue");
    expect(errors).toEqual([]);

    container.remove();
  });
});
