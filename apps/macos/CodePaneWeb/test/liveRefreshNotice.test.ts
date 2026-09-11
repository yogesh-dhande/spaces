import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it, vi } from "vitest";
import { createLiveRefreshNotice } from "../src/app/liveRefreshNotice";

// Read via Node's `node:fs`/`node:url`, not a Vite `?raw` import: this repo's vitest.config.ts
// sets `test.css: false`, so jsdom never applies app.css and a mounted `.live-refresh-notice[hidden]`
// element would look "shown" to any assertion that only checks computed style. That is exactly the
// bug this regression test targets: `.live-refresh-notice { display: flex }` outranks the browser's
// default `[hidden] { display: none }` rule unless an explicit `[hidden]` override exists, so the
// notice box painted empty instead of disappearing. Since jsdom cannot exercise CSS specificity, a
// text-level assertion that the override rule exists in the source file is the right level here.
const APP_CSS_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "../src/styles/app.css");

describe("app.css [hidden] override (regression)", () => {
  it("defines .live-refresh-notice[hidden] { display: none }, overriding the class's own display: flex", () => {
    const css = readFileSync(APP_CSS_PATH, "utf8");
    const rule = css.match(/\.live-refresh-notice\[hidden\]\s*\{([^}]*)\}/);
    expect(rule).not.toBeNull();
    expect(rule![1]).toMatch(/display:\s*none/);
  });

  // Regression: the box is absolutely positioned with no width constraint of its own, so a long
  // daemon error (e.g. a Linux inotify-limit message) never reaches its label's `text-overflow:
  // ellipsis` and instead runs past the container in a narrow pane. Same text-level reasoning as
  // the test above applies: jsdom never applies this stylesheet, so this checks the rules exist
  // in the source rather than the computed layout they would otherwise produce.
  it("constrains .live-refresh-notice's width and lets its label shrink so a long reason ellipsizes", () => {
    const css = readFileSync(APP_CSS_PATH, "utf8");
    const boxRule = css.match(/\.live-refresh-notice\s*\{([^}]*)\}/);
    expect(boxRule).not.toBeNull();
    expect(boxRule![1]).toMatch(/max-width/);
    const labelRule = css.match(/\.live-refresh-notice-label\s*\{([^}]*)\}/);
    expect(labelRule).not.toBeNull();
    expect(labelRule![1]).toMatch(/min-width:\s*0/);
  });
});

describe("createLiveRefreshNotice", () => {
  it("starts hidden, carrying the product's stable element id", () => {
    const notice = createLiveRefreshNotice();
    expect(notice.el.id).toBe("code-pane-live-refresh-notice");
    expect(notice.el.hidden).toBe(true);
  });

  it("show() displays the reason verbatim and wires the Retry button to the given handler", () => {
    const notice = createLiveRefreshNotice();
    notice.attachTo(document.createElement("div"));
    const onRetry = vi.fn();
    notice.show("fsevents: too many open files", onRetry);

    expect(notice.el.hidden).toBe(false);
    expect(notice.el.textContent).toContain("Live refresh off: fsevents: too many open files");
    const button = notice.el.querySelector("button")!;
    expect(button.textContent).toBe("Retry");
    expect(button.disabled).toBe(false);

    button.click();
    expect(onRetry).toHaveBeenCalledTimes(1);
  });

  it("hide() hides the element and drops the retry handler", () => {
    const notice = createLiveRefreshNotice();
    notice.attachTo(document.createElement("div"));
    const onRetry = vi.fn();
    notice.show("some reason", onRetry);

    notice.hide();

    expect(notice.el.hidden).toBe(true);
    notice.el.querySelector("button")!.click();
    expect(onRetry).not.toHaveBeenCalled();
  });

  it("setRetrying toggles the Retry button between its idle and disabled in-flight labels", () => {
    const notice = createLiveRefreshNotice();
    notice.attachTo(document.createElement("div"));
    notice.show("some reason", vi.fn());
    const button = notice.el.querySelector("button")! as HTMLButtonElement;

    notice.setRetrying(true);
    expect(button.disabled).toBe(true);
    expect(button.textContent).toBe("Retrying…");

    notice.setRetrying(false);
    expect(button.disabled).toBe(false);
    expect(button.textContent).toBe("Retry");
  });

  it("only the Retry button takes clicks: the banner and its label are pointer-events: none", () => {
    const notice = createLiveRefreshNotice();
    notice.attachTo(document.createElement("div"));
    notice.show("some reason", vi.fn());

    expect(notice.el.style.pointerEvents).toBe("none");
    const button = notice.el.querySelector("button")! as HTMLButtonElement;
    expect(button.style.pointerEvents).toBe("auto");
  });

  /** A transient `.banner` (editorView.ts's conflict/error/merge banner, diffView.ts's inline-edit
   *  error banner, commentsController.ts's send-failure banner) toggles its own visibility through
   *  `style.display`, never an event. These tests drive that same toggle directly on a plain `div`
   *  standing in for one, since the arbitration in liveRefreshNotice.ts reads the DOM state rather
   *  than depending on which owner put the banner up. */
  describe("banner arbitration (docs/design.md: a pane has one banner)", () => {
    function addTransientBanner(container: HTMLElement, displayed: boolean): HTMLElement {
      const banner = document.createElement("div");
      banner.className = "banner error";
      banner.style.display = displayed ? "flex" : "none";
      container.appendChild(banner);
      return banner;
    }

    it("hides once a sibling transient banner becomes visible, and reappears once it clears", async () => {
      const notice = createLiveRefreshNotice();
      const container = document.createElement("div");
      const transientBanner = addTransientBanner(container, false);

      notice.attachTo(container);
      notice.show("watcher failed", vi.fn());
      expect(notice.el.hidden).toBe(false);

      transientBanner.style.display = "flex";
      await vi.waitFor(() => expect(notice.el.hidden).toBe(true));

      transientBanner.style.display = "none";
      await vi.waitFor(() => expect(notice.el.hidden).toBe(false));
    });

    it("re-attaching to a different container stops watching the old one and starts watching the new one", async () => {
      const notice = createLiveRefreshNotice();
      const oldContainer = document.createElement("div");
      const oldBanner = addTransientBanner(oldContainer, false);
      const newContainer = document.createElement("div");
      const newBanner = addTransientBanner(newContainer, false);

      notice.attachTo(oldContainer);
      notice.show("watcher failed", vi.fn());
      expect(notice.el.hidden).toBe(false);

      notice.attachTo(newContainer);
      expect(notice.el.hidden).toBe(false);

      // The old container's banner has no effect once this handle has moved on from it.
      oldBanner.style.display = "flex";
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(notice.el.hidden).toBe(false);

      // The new container's banner does.
      newBanner.style.display = "flex";
      await vi.waitFor(() => expect(notice.el.hidden).toBe(true));
    });

    it("hide() while a transient banner is up stays hidden once the banner clears", async () => {
      const notice = createLiveRefreshNotice();
      const container = document.createElement("div");
      const transientBanner = addTransientBanner(container, true);

      notice.attachTo(container);
      notice.show("watcher failed", vi.fn());
      expect(notice.el.hidden).toBe(true); // already suppressed by the transient banner

      notice.hide();
      expect(notice.el.hidden).toBe(true);

      transientBanner.style.display = "none";
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(notice.el.hidden).toBe(true); // stays hidden: the pane has nothing to show either way
    });
  });
});
