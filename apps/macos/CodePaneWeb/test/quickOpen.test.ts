import { beforeEach, describe, expect, it, vi } from "vitest";
import { WorkspaceFileListResult } from "../src/bridge/types";
import { WorkspaceFileListCache } from "../src/app/workspaceFileListCache";
import { QuickOpen, QuickOpenCallbacks } from "../src/app/quickOpen";
import { fuzzyMatch } from "../src/app/fuzzyMatch";

// jsdom has no scrollIntoView implementation; highlightSelection calls it on the selected row.
beforeEach(() => {
  Element.prototype.scrollIntoView = vi.fn();
});

// Wraps the real implementation in a `vi.fn()` (rather than a fake scorer) so every other test's
// ranking/highlighting assertions still exercise real fuzzyMatch behavior; this only adds a call
// count the candidate-narrowing tests below can inspect.
vi.mock("../src/app/fuzzyMatch", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/app/fuzzyMatch")>();
  return { fuzzyMatch: vi.fn(actual.fuzzyMatch) };
});

function makeResult(paths: string[], truncated = false): WorkspaceFileListResult {
  return { paths, truncated };
}

/** Builds a real `WorkspaceFileListCache` over a `vi.fn()` bridge stub — exercises the real
 *  cache/overlay integration rather than mocking the cache class away. */
function makeCache(workspaceFileList = vi.fn().mockResolvedValue(makeResult([]))): {
  cache: WorkspaceFileListCache;
  bridge: ReturnType<typeof vi.fn>;
} {
  const cache = new WorkspaceFileListCache({ workspaceFileList });
  return { cache, bridge: workspaceFileList };
}

function makeCallbacks(overrides: Partial<QuickOpenCallbacks> = {}): QuickOpenCallbacks {
  return {
    getMode: () => "editor",
    isInDiff: () => false,
    openInDiff: vi.fn(),
    openInEditor: vi.fn(),
    ...overrides,
  };
}

function makeHost(): HTMLElement {
  return document.createElement("div");
}

function backdropOf(host: HTMLElement): HTMLElement {
  return host.querySelector(".quick-open-backdrop") as HTMLElement;
}

function rowPaths(host: HTMLElement): (string | undefined)[] {
  return [...host.querySelectorAll(".row")].map((row) => row.getAttribute("data-path") ?? undefined);
}

function rowId(path: string): string {
  return `code-pane-quick-open-${encodeURIComponent(path)}`;
}

function inputOf(host: HTMLElement): HTMLInputElement {
  return host.querySelector("input") as HTMLInputElement;
}

function dispatchCmdP(shiftKey = false): void {
  window.dispatchEvent(
    new KeyboardEvent("keydown", { key: "p", metaKey: true, shiftKey, bubbles: true, cancelable: true }),
  );
}

describe("QuickOpen — ⌘P activation", () => {
  it("⌘P shows the overlay and focuses the input", () => {
    // jsdom only tracks document.activeElement for elements attached to the document, so this one
    // test attaches host to document.body (and removes it afterward) rather than using a detached
    // host like every other test in this file.
    const { cache } = makeCache();
    const host = makeHost();
    document.body.appendChild(host);
    try {
      new QuickOpen(host, cache, () => [], makeCallbacks());

      expect(backdropOf(host).style.display).toBe("none");

      dispatchCmdP();

      expect(backdropOf(host).style.display).toBe("flex");
      expect(document.activeElement).toBe(inputOf(host));
    } finally {
      host.remove();
    }
  });

  it("⌘⇧P does not trigger the overlay", () => {
    const { cache } = makeCache();
    const host = makeHost();
    new QuickOpen(host, cache, () => [], makeCallbacks());

    dispatchCmdP(/* shiftKey */ true);

    expect(backdropOf(host).style.display).toBe("none");
  });
});

describe("QuickOpen — recents before typing", () => {
  it("shows recents unfiltered before the listing resolves, then filters out a path the listing excludes", async () => {
    const bridge = vi.fn();
    const { promise, resolve } = (() => {
      let resolveFn!: (value: WorkspaceFileListResult) => void;
      const p = new Promise<WorkspaceFileListResult>((res) => {
        resolveFn = res;
      });
      return { promise: p, resolve: resolveFn };
    })();
    bridge.mockReturnValue(promise);
    const { cache } = makeCache(bridge);
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => ["a.ts", "b.ts", "c.ts"], makeCallbacks());

    quickOpen.show();

    // Listing hasn't resolved yet — recents render unfiltered.
    expect(rowPaths(host)).toEqual(["a.ts", "b.ts", "c.ts"]);

    // The listing excludes "b.ts" (e.g. deleted on disk but not yet dropped from recentPaths).
    resolve(makeResult(["a.ts", "c.ts"]));

    await vi.waitFor(() => expect(rowPaths(host)).toEqual(["a.ts", "c.ts"]));
  });

  // Finding D: a recent path's absence from a *truncated* listing isn't evidence the file is gone —
  // it may simply have sorted past the cap — so filtering must be skipped in that case, unlike the
  // complete-listing case above which does filter.
  it("does not filter recents against a truncated listing, even though the listing excludes one", async () => {
    const { cache } = makeCache(vi.fn().mockResolvedValue(makeResult(["a.ts", "c.ts"], /* truncated */ true)));
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => ["a.ts", "b.ts", "c.ts"], makeCallbacks());

    quickOpen.show();
    await vi.waitFor(() => expect(rowPaths(host)).toEqual(["a.ts", "b.ts", "c.ts"]));
  });
});

describe("QuickOpen — revalidation on show() (Finding 1)", () => {
  it("opening with an already-cached listing shows it instantly, then re-renders when a background revalidation lands a newly-added file", async () => {
    const bridge = vi.fn();
    bridge.mockResolvedValueOnce(makeResult(["a.ts"]));
    const { promise: freshPromise, resolve: resolveFresh } = (() => {
      let resolveFn!: (value: WorkspaceFileListResult) => void;
      const p = new Promise<WorkspaceFileListResult>((res) => {
        resolveFn = res;
      });
      return { promise: p, resolve: resolveFn };
    })();
    bridge.mockReturnValueOnce(freshPromise);
    const { cache } = makeCache(bridge);
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => [], makeCallbacks());

    // First open populates the cache (a non-git workspace or a pane still on its first Editor
    // render never gets root.ts's diff-signature invalidation, so this open is the only signal).
    quickOpen.show();
    await new Promise((resolve) => setTimeout(resolve, 0)); // flush the first fetch's .then()
    expect(bridge).toHaveBeenCalledTimes(1);
    const input = inputOf(host);
    input.value = "new";
    input.dispatchEvent(new Event("input"));
    expect(rowPaths(host)).toEqual([]); // "new.ts" doesn't exist in the workspace yet
    quickOpen.close();

    // Reopening serves the cached listing instantly (no visible gap) while kicking a background
    // revalidation — this is the fix: root.ts's diff-signature push never fires here, so without
    // show()-time revalidation this cache would stay stale forever.
    quickOpen.show();
    expect(bridge).toHaveBeenCalledTimes(2);
    input.value = "new";
    input.dispatchEvent(new Event("input"));
    expect(rowPaths(host)).toEqual([]); // still stale until the revalidation resolves

    resolveFresh(makeResult(["a.ts", "new.ts"]));
    await vi.waitFor(() => expect(rowPaths(host)).toEqual(["new.ts"]));
  });
});

describe("QuickOpen — selection clamped on async refresh", () => {
  it("keeps the last row selected (not none) when a background fetch resolves a shorter result set", async () => {
    const bridge = vi.fn();
    const { promise, resolve } = (() => {
      let resolveFn!: (value: WorkspaceFileListResult) => void;
      const p = new Promise<WorkspaceFileListResult>((res) => {
        resolveFn = res;
      });
      return { promise: p, resolve: resolveFn };
    })();
    bridge.mockReturnValue(promise);
    const { cache } = makeCache(bridge);
    const host = makeHost();
    const callbacks = makeCallbacks();
    const quickOpen = new QuickOpen(host, cache, () => ["a.ts", "b.ts", "c.ts"], callbacks);

    quickOpen.show();
    // Arrow down to the last of the three recents, before the listing fetch resolves.
    const input = inputOf(host);
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true }));
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true }));
    const selIndex = (): number => [...host.querySelectorAll(".row")].findIndex((r) => r.classList.contains("sel"));
    expect(selIndex()).toBe(2);

    // The listing now excludes "b.ts" and "c.ts" — recents filters down to a single row, leaving
    // the previous selectedIndex (2) past the end of the new, shorter results.
    resolve(makeResult(["a.ts"]));
    await vi.waitFor(() => expect(rowPaths(host)).toEqual(["a.ts"]));

    expect(selIndex()).toBe(0); // clamped to the last (and only) row, not left dangling past the end
    inputOf(host).dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    expect(callbacks.openInEditor).toHaveBeenCalledWith("a.ts");
  });
});

describe("QuickOpen — typing triggers fuzzy search", () => {
  it("ranks results by fuzzyMatch score once the listing has loaded", async () => {
    const { cache } = makeCache(vi.fn().mockResolvedValue(makeResult(["src/xfoo.ts", "src/foo.ts"])));
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => [], makeCallbacks());

    quickOpen.show();

    const input = inputOf(host);
    input.value = "foo";
    input.dispatchEvent(new Event("input"));

    // "src/foo.ts" scores higher: its "f" lands right at a path-segment start (after "/"), while
    // "src/xfoo.ts"'s "f" does not — see fuzzyMatch.ts's SEGMENT_START_BONUS.
    await vi.waitFor(() => expect(rowPaths(host)).toEqual(["src/foo.ts", "src/xfoo.ts"]));
  });
});

describe("QuickOpen — accessibility identifiers", () => {
  it("exposes the search and results with combobox/listbox semantics", async () => {
    const { cache } = makeCache(vi.fn().mockResolvedValue(makeResult(["src/a.ts", "src/b.ts"])));
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => [], makeCallbacks());

    quickOpen.show();
    const input = inputOf(host);
    input.value = "src";
    input.dispatchEvent(new Event("input"));
    await vi.waitFor(() => expect(input.getAttribute("role")).toBe("combobox"));
    const list = host.querySelector('[role="listbox"]');
    expect(list?.id).toBe("code-pane-quick-open-list");
    expect(input.getAttribute("aria-controls")).toBe(list?.id);
    await vi.waitFor(() => expect(host.querySelectorAll('[role="option"]')).toHaveLength(2));
    const rows = [...host.querySelectorAll<HTMLElement>('[role="option"]')];
    const first = rows[0]!;
    const second = rows[1]!;
    expect(first.getAttribute("aria-selected")).toBe("true");
    expect(second.getAttribute("aria-selected")).toBe("false");
    expect(input.getAttribute("aria-activedescendant")).toBe(first.id);
  });

  it("marks the empty state with a stable identifier", async () => {
    const { cache } = makeCache(vi.fn().mockResolvedValue(makeResult(["a.ts"])));
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => [], makeCallbacks());

    quickOpen.show();
    const input = inputOf(host);
    input.value = "missing.ts";
    input.dispatchEvent(new Event("input"));

    await vi.waitFor(() => expect(host.querySelector("#code-pane-quick-open-empty")).not.toBeNull());
  });

  it("marks each result row with a path-derived stable identifier", async () => {
    const { cache } = makeCache(vi.fn().mockResolvedValue(makeResult(["src/a.ts", "src/b.ts"])));
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => [], makeCallbacks());

    quickOpen.show();
    const input = inputOf(host);
    input.value = "src";
    input.dispatchEvent(new Event("input"));

    await vi.waitFor(() => expect(host.querySelector(`[id="${rowId("src/a.ts")}"]`)).not.toBeNull());
    expect(host.querySelector(`[id="${rowId("src/b.ts")}"]`)).not.toBeNull();
  });

  it("clears the active descendant when a populated result list becomes empty", async () => {
    const { cache } = makeCache(vi.fn().mockResolvedValue(makeResult(["src/a.ts"])));
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => [], makeCallbacks());

    quickOpen.show();
    const input = inputOf(host);
    input.value = "src";
    input.dispatchEvent(new Event("input"));
    await vi.waitFor(() => expect(host.querySelector('[role="option"]')).not.toBeNull());
    expect(input.getAttribute("aria-activedescendant")).not.toBeNull();

    input.value = "missing";
    input.dispatchEvent(new Event("input"));
    await vi.waitFor(() => expect(host.querySelector('[role="option"]')).toBeNull());
    expect(input.getAttribute("aria-activedescendant")).toBeNull();
  });
});

describe("QuickOpen — fuzzy-match candidate narrowing", () => {
  // "src/abc.ts" and "src/abx.ts" and "src/ab-other.ts" all match "ab" (right after the "/"
  // segment start); only "src/abc.ts" also matches "abc". "readme.md" matches neither.
  const paths = ["src/abc.ts", "src/abx.ts", "src/ab-other.ts", "readme.md"];

  async function openLoaded(): Promise<{ host: HTMLElement; quickOpen: QuickOpen }> {
    const { cache } = makeCache(vi.fn().mockResolvedValue(makeResult([...paths])));
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => [], makeCallbacks());
    quickOpen.show();
    await new Promise((resolve) => setTimeout(resolve, 0)); // flush the listing fetch
    return { host, quickOpen };
  }

  function typeInto(host: HTMLElement, value: string): void {
    const input = inputOf(host);
    input.value = value;
    input.dispatchEvent(new Event("input"));
  }

  it("typing incrementally yields the same results as typing the final query fresh", async () => {
    const { host: incrementalHost } = await openLoaded();
    typeInto(incrementalHost, "a");
    typeInto(incrementalHost, "ab");
    typeInto(incrementalHost, "abc");
    const incrementalResults = rowPaths(incrementalHost);

    const { host: freshHost } = await openLoaded();
    typeInto(freshHost, "abc");
    const freshResults = rowPaths(freshHost);

    expect(incrementalResults).toEqual(freshResults);
    expect(incrementalResults).toEqual(["src/abc.ts"]);
  });

  it("backspacing brings back a match the longer query excluded", async () => {
    const { host } = await openLoaded();
    typeInto(host, "abc");
    expect(rowPaths(host)).toEqual(["src/abc.ts"]);

    typeInto(host, "ab");
    // "src/abx.ts" and "src/ab-other.ts" match "ab" but were excluded by "abc" above; all three
    // score equally (same segment-start + basename position), so insertion order breaks the tie.
    expect(rowPaths(host)).toEqual(["src/abc.ts", "src/abx.ts", "src/ab-other.ts"]);
  });

  it("narrows fuzzyMatch's scan to the previous query's match set on an extending keystroke", async () => {
    const { host } = await openLoaded();
    typeInto(host, "ab");
    expect(rowPaths(host)).toEqual(["src/abc.ts", "src/abx.ts", "src/ab-other.ts"]);
    vi.mocked(fuzzyMatch).mockClear();

    typeInto(host, "abc"); // extends "ab" -> rescans only its 3 matches, not all 4 cached paths
    expect(fuzzyMatch).toHaveBeenCalledTimes(3);
    expect(rowPaths(host)).toEqual(["src/abc.ts"]);
  });

  it("a query typed before a listing refresh matches the refreshed listing, not a stale narrowed set", async () => {
    const bridge = vi.fn();
    bridge.mockResolvedValueOnce(makeResult(["src/abc.ts"]));
    const { promise: freshPromise, resolve: resolveFresh } = (() => {
      let resolveFn!: (value: WorkspaceFileListResult) => void;
      const p = new Promise<WorkspaceFileListResult>((res) => {
        resolveFn = res;
      });
      return { promise: p, resolve: resolveFn };
    })();
    bridge.mockReturnValueOnce(freshPromise);
    const { cache } = makeCache(bridge);
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => [], makeCallbacks());

    quickOpen.show();
    await new Promise((resolve) => setTimeout(resolve, 0)); // first fetch resolves: ["src/abc.ts"]
    typeInto(host, "abc");
    expect(rowPaths(host)).toEqual(["src/abc.ts"]);
    quickOpen.close();

    // Reopening resets the input but kicks a background revalidation (still pending) — typing the
    // same-shaped query again builds narrowing state against the OLD listing, in which it matches
    // nothing yet.
    quickOpen.show();
    typeInto(host, "abd");
    expect(rowPaths(host)).toEqual([]);

    // The refreshed listing adds a file only "abd" matches. If the narrowing state from the line
    // above survived the refresh, this would still show no matches (query is unchanged, so it would
    // "extend" its own stale, empty candidate set instead of rescanning the fresh listing).
    resolveFresh(makeResult(["src/abc.ts", "src/abd.ts"]));
    await vi.waitFor(() => expect(rowPaths(host)).toEqual(["src/abd.ts"]));
  });
});

describe("QuickOpen — keyboard navigation", () => {
  it("ArrowDown/ArrowUp move the selection, clamped at both bounds", () => {
    const { cache } = makeCache();
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => ["a.ts", "b.ts", "c.ts"], makeCallbacks());
    quickOpen.show();

    const input = inputOf(host);
    const selIndex = (): number => [...host.querySelectorAll(".row")].findIndex((r) => r.classList.contains("sel"));
    expect(selIndex()).toBe(0);

    input.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true, cancelable: true }));
    expect(selIndex()).toBe(0); // clamped — cannot go negative

    input.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true }));
    expect(selIndex()).toBe(1);
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true }));
    expect(selIndex()).toBe(2);
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true }));
    expect(selIndex()).toBe(2); // clamped — cannot exceed the last result
  });

  it("ArrowDown scrolls the newly selected row into view", () => {
    const { cache } = makeCache();
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => ["a.ts", "b.ts", "c.ts"], makeCallbacks());
    quickOpen.show();

    const input = inputOf(host);

    input.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true }));

    const row = host.querySelector('.row[data-path="b.ts"]') as HTMLElement;
    expect(row.scrollIntoView).toHaveBeenCalledWith({ block: "nearest" });
  });

  it("Escape closes the overlay without opening anything", () => {
    const callbacks = makeCallbacks();
    const { cache } = makeCache();
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => ["a.ts"], callbacks);
    quickOpen.show();

    inputOf(host).dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));

    expect(backdropOf(host).style.display).toBe("none");
    expect(callbacks.openInEditor).not.toHaveBeenCalled();
    expect(callbacks.openInDiff).not.toHaveBeenCalled();
  });
});

describe("QuickOpen — open semantics", () => {
  it("in editor mode, Enter always opens via openInEditor regardless of isInDiff", () => {
    const callbacks = makeCallbacks({ getMode: () => "editor", isInDiff: () => true });
    const { cache } = makeCache();
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => ["a.ts"], callbacks);
    quickOpen.show();

    inputOf(host).dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    expect(callbacks.openInEditor).toHaveBeenCalledWith("a.ts");
    expect(callbacks.openInDiff).not.toHaveBeenCalled();
  });

  it("in diff mode, clicking a result already in the diff opens via openInDiff", () => {
    const callbacks = makeCallbacks({ getMode: () => "diff", isInDiff: (path) => path === "a.ts" });
    const { cache } = makeCache();
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => ["a.ts"], callbacks);
    quickOpen.show();

    const row = host.querySelector('.row[data-path="a.ts"]') as HTMLElement;
    row.click();

    expect(callbacks.openInDiff).toHaveBeenCalledWith("a.ts");
    expect(callbacks.openInEditor).not.toHaveBeenCalled();
  });

  it("in diff mode, Enter on a result NOT in the diff opens via openInEditor instead", () => {
    const callbacks = makeCallbacks({ getMode: () => "diff", isInDiff: () => false });
    const { cache } = makeCache();
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => ["a.ts"], callbacks);
    quickOpen.show();

    inputOf(host).dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    expect(callbacks.openInEditor).toHaveBeenCalledWith("a.ts");
    expect(callbacks.openInDiff).not.toHaveBeenCalled();
  });
});

describe("QuickOpen — backdrop dismissal", () => {
  it("a mousedown landing directly on the backdrop closes the overlay", () => {
    const { cache } = makeCache();
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => [], makeCallbacks());
    quickOpen.show();

    backdropOf(host).dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true }));

    expect(backdropOf(host).style.display).toBe("none");
  });

  it("a mousedown inside the panel does not close the overlay", () => {
    const { cache } = makeCache();
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => [], makeCallbacks());
    quickOpen.show();

    const panel = host.querySelector(".quick-open") as HTMLElement;
    panel.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true }));

    expect(backdropOf(host).style.display).toBe("flex");
  });
});

describe("QuickOpen — failed listing fetch", () => {
  it("does not throw or surface an unhandled rejection; recents still render", async () => {
    const bridge = vi.fn().mockRejectedValue(new Error("network down"));
    const { cache } = makeCache(bridge);
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => ["a.ts", "b.ts"], makeCallbacks());

    quickOpen.show();
    expect(rowPaths(host)).toEqual(["a.ts", "b.ts"]);

    await vi.waitFor(() => expect(bridge).toHaveBeenCalledTimes(1));
    // Give the rejected promise's .catch() a turn to run; recents must still be showing afterward,
    // with no crash — this is the exact bug the recently-added .catch() guards against regressing.
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(rowPaths(host)).toEqual(["a.ts", "b.ts"]);
  });
});

describe("QuickOpen — refreshListing (root.ts diff-signature push)", () => {
  it("while open, refetches and re-renders the current query against the new listing", async () => {
    const bridge = vi.fn();
    bridge.mockResolvedValueOnce(makeResult(["only-l1.ts", "common.ts"])); // show()'s initial fetch
    const { promise: freshPromise, resolve: resolveFresh } = (() => {
      let resolveFn!: (value: WorkspaceFileListResult) => void;
      const p = new Promise<WorkspaceFileListResult>((res) => {
        resolveFn = res;
      });
      return { promise: p, resolve: resolveFn };
    })();
    bridge.mockReturnValueOnce(freshPromise); // refreshListing()'s fetch
    const { cache } = makeCache(bridge);
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => [], makeCallbacks());

    quickOpen.show();
    await new Promise((resolve) => setTimeout(resolve, 0)); // flush the initial fetch
    const input = inputOf(host);
    input.value = "only";
    input.dispatchEvent(new Event("input"));
    expect(rowPaths(host)).toEqual(["only-l1.ts"]);

    // Simulates root.ts's resubscribeDiffSignature callback: fileListCache.invalidate() followed by
    // quickOpen.refreshListing(), ungated on pane mode.
    cache.invalidate();
    quickOpen.refreshListing();
    expect(bridge).toHaveBeenCalledTimes(2); // started a fresh fetch rather than reusing anything stale

    // "only-l1.ts" (L1-only) drops out; "only-l2.ts" (L2-only) shows up, for the same unchanged query.
    resolveFresh(makeResult(["only-l2.ts", "common.ts"]));
    await vi.waitFor(() => expect(rowPaths(host)).toEqual(["only-l2.ts"]));
  });

  it("does nothing while the overlay is closed", () => {
    const bridge = vi.fn().mockResolvedValue(makeResult(["a.ts"]));
    const { cache } = makeCache(bridge);
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => [], makeCallbacks());

    quickOpen.refreshListing();

    expect(bridge).not.toHaveBeenCalled();
  });
});

describe("QuickOpen — focus restore on close (Fix 1)", () => {
  // jsdom only tracks document.activeElement for elements attached to the document, so these tests
  // attach host (and the "prior" control) to document.body, like the ⌘P activation test above.
  it("restores focus to the previously focused element on Escape", () => {
    const { cache } = makeCache();
    const host = makeHost();
    const priorBtn = document.createElement("button");
    document.body.appendChild(host);
    document.body.appendChild(priorBtn);
    try {
      priorBtn.focus();
      expect(document.activeElement).toBe(priorBtn);
      const quickOpen = new QuickOpen(host, cache, () => [], makeCallbacks());

      quickOpen.show();
      expect(document.activeElement).toBe(inputOf(host));

      inputOf(host).dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));

      expect(document.activeElement).toBe(priorBtn);
    } finally {
      host.remove();
      priorBtn.remove();
    }
  });

  it("restores focus to the previously focused element after picking a result via Enter", () => {
    const { cache } = makeCache();
    const host = makeHost();
    const priorInput = document.createElement("input");
    document.body.appendChild(host);
    document.body.appendChild(priorInput);
    try {
      priorInput.focus();
      const quickOpen = new QuickOpen(host, cache, () => ["a.ts"], makeCallbacks());

      quickOpen.show();
      expect(document.activeElement).toBe(inputOf(host));

      inputOf(host).dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

      expect(document.activeElement).toBe(priorInput);
    } finally {
      host.remove();
      priorInput.remove();
    }
  });

  it("does not throw and does not restore focus when the prior element was removed from the DOM before close", () => {
    const { cache } = makeCache();
    const host = makeHost();
    const priorBtn = document.createElement("button");
    document.body.appendChild(host);
    document.body.appendChild(priorBtn);
    try {
      priorBtn.focus();
      const quickOpen = new QuickOpen(host, cache, () => [], makeCallbacks());

      quickOpen.show();
      priorBtn.remove(); // disconnected before close() runs

      expect(() => {
        inputOf(host).dispatchEvent(
          new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
        );
      }).not.toThrow();

      expect(document.activeElement).not.toBe(priorBtn);
    } finally {
      host.remove();
    }
  });

  it("a second show() while already open (⌘P pressed twice) keeps the original prior element for restore", () => {
    // Exercises show()'s own already-open guard directly rather than via a global `window`
    // keydown dispatch: every QuickOpen constructed anywhere in this file registers its own
    // undisposed window listener (see the constructor), so a real ⌘P dispatch this deep into the
    // suite would also re-trigger every earlier test's now-defunct instance. Calling show() again
    // on this instance runs the exact same body the window listener invokes.
    const { cache } = makeCache();
    const host = makeHost();
    const priorBtn = document.createElement("button");
    document.body.appendChild(host);
    document.body.appendChild(priorBtn);
    try {
      priorBtn.focus();
      const quickOpen = new QuickOpen(host, cache, () => [], makeCallbacks());

      quickOpen.show();
      expect(document.activeElement).toBe(inputOf(host));

      // ⌘P again while open must not overwrite the captured prior element with the overlay's own
      // (currently focused) input.
      quickOpen.show();
      expect(document.activeElement).toBe(inputOf(host));

      quickOpen.close();

      expect(document.activeElement).toBe(priorBtn);
    } finally {
      host.remove();
      priorBtn.remove();
    }
  });
});

describe("QuickOpen — seeds from another consumer's cache snapshot on show() (cross-consumer stale paint)", () => {
  it("fuzzy-matches against a listing this instance never fetched itself, immediately, before its own revalidation resolves", async () => {
    const bridge = vi.fn();
    bridge.mockResolvedValueOnce(makeResult(["src/foo.ts", "src/bar.ts"])); // another consumer's fetch
    // `resolve` is deliberately never called: this fetch is meant to stay pending for the whole test.
    const { promise: freshPromise, resolve: _resolveFresh } = (() => {
      let resolveFn!: (value: WorkspaceFileListResult) => void;
      const p = new Promise<WorkspaceFileListResult>((res) => {
        resolveFn = res;
      });
      return { promise: p, resolve: resolveFn };
    })();
    bridge.mockReturnValueOnce(freshPromise); // this instance's own show()-time getFresh(), left pending
    const { cache } = makeCache(bridge);

    // Simulates another consumer (e.g. the Files tab) having already populated the shared cache —
    // this QuickOpen instance is constructed fresh afterward and has never fetched anything itself.
    await cache.get();

    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => [], makeCallbacks());

    quickOpen.show();
    // Its own getFresh() call is in flight (bridge call 2, deliberately left unresolved) but the
    // snapshot seeded synchronously at show() already lets typing match real results — this is the
    // fix: without it, cachedPaths would still be empty here.
    expect(bridge).toHaveBeenCalledTimes(2);
    const input = inputOf(host);
    input.value = "foo";
    input.dispatchEvent(new Event("input"));

    expect(rowPaths(host)).toEqual(["src/foo.ts"]);
  });
});

describe("QuickOpen — truncated listing note", () => {
  it("reflects WorkspaceFileListResult.truncated on the note element's hidden attribute", async () => {
    const { cache } = makeCache(vi.fn().mockResolvedValue(makeResult(["a.ts"], /* truncated */ true)));
    const host = makeHost();
    const quickOpen = new QuickOpen(host, cache, () => [], makeCallbacks());

    quickOpen.show();
    expect((host.querySelector(".note") as HTMLElement).hidden).toBe(true); // not yet loaded

    await vi.waitFor(() => expect((host.querySelector(".note") as HTMLElement).hidden).toBe(false));
  });
});
