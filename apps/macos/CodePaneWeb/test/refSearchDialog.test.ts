import { describe, expect, it, vi, beforeEach } from "vitest";
import { WorkspaceRefListResult } from "../src/bridge/types";
import { RefSearchDialog, RefSearchDialogCallbacks } from "../src/app/refSearchDialog";

// jsdom has no scrollIntoView implementation; highlightSelection calls it on the selected row.
beforeEach(() => {
  Element.prototype.scrollIntoView = vi.fn();
});

function makeListing(overrides: Partial<WorkspaceRefListResult> = {}): WorkspaceRefListResult {
  return {
    branches: ["main", "feature/x"],
    branchesTruncated: false,
    commits: [
      { sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", subject: "Fix the flaky test" },
      { sha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", subject: "Add compare menu" },
    ],
    commitsTruncated: false,
    ...overrides,
  };
}

function makeCallbacks(overrides: Partial<RefSearchDialogCallbacks> = {}): RefSearchDialogCallbacks {
  return { onSelect: vi.fn(), ...overrides };
}

function makeHost(): HTMLElement {
  return document.createElement("div");
}

/** Controllable promise for asserting on in-flight/latest-wins behavior. */
function deferred<T>(): { promise: Promise<T>; resolve: (value: T) => void } {
  let resolveFn!: (value: T) => void;
  const promise = new Promise<T>((res) => {
    resolveFn = res;
  });
  return { promise, resolve: resolveFn };
}

function backdropOf(host: HTMLElement): HTMLElement {
  return host.querySelector(".quick-open-backdrop") as HTMLElement;
}

function inputOf(host: HTMLElement): HTMLInputElement {
  return host.querySelector("input") as HTMLInputElement;
}

function rowsOf(host: HTMLElement): HTMLElement[] {
  return [...host.querySelectorAll<HTMLElement>(".row")];
}

function rowTexts(host: HTMLElement): string[] {
  return rowsOf(host).map((row) => row.textContent ?? "");
}

function typeInto(host: HTMLElement, value: string): void {
  const input = inputOf(host);
  input.value = value;
  input.dispatchEvent(new Event("input"));
}

describe("RefSearchDialog — loading the listing", () => {
  it("calls listRefs on show() and renders a loading state until it resolves", async () => {
    const { promise, resolve } = deferred<WorkspaceRefListResult>();
    const listRefs = vi.fn().mockReturnValue(promise);
    const host = makeHost();
    const dialog = new RefSearchDialog(host, listRefs, "main", makeCallbacks());

    dialog.show("branch");
    expect(listRefs).toHaveBeenCalledTimes(1);
    expect(host.querySelector(".empty")?.textContent).toBe("Loading…");

    resolve(makeListing());
    await vi.waitFor(() => expect(rowTexts(host)).toEqual(["mainbase", "feature/x"]));
  });

  it("fetches fresh on every show() rather than caching the previous listing", async () => {
    const listRefs = vi.fn().mockResolvedValue(makeListing());
    const host = makeHost();
    const dialog = new RefSearchDialog(host, listRefs, "main", makeCallbacks());

    dialog.show("branch");
    await vi.waitFor(() => expect(listRefs).toHaveBeenCalledTimes(1));
    dialog.close();

    dialog.show("branch");
    expect(listRefs).toHaveBeenCalledTimes(2);
  });
});

describe("RefSearchDialog — branch mode", () => {
  it("fuzzy-filters branches and highlights the matched characters", async () => {
    const listRefs = vi.fn().mockResolvedValue(makeListing({ branches: ["main", "feature/x", "release/1.2"] }));
    const host = makeHost();
    const dialog = new RefSearchDialog(host, listRefs, "main", makeCallbacks());

    dialog.show("branch");
    await vi.waitFor(() => expect(rowTexts(host).length).toBeGreaterThan(0));

    typeInto(host, "feat");
    expect(rowTexts(host)).toEqual(["feature/x"]);
    const mark = rowsOf(host)[0]!.querySelector("mark");
    expect(mark).not.toBeNull();
    expect(mark!.textContent).toBe("feat");
  });

  it("sorts the workspace's base branch first, badged, even when it isn't the first match", async () => {
    const listRefs = vi.fn().mockResolvedValue(makeListing({ branches: ["zeta", "main", "alpha"] }));
    const host = makeHost();
    const dialog = new RefSearchDialog(host, listRefs, "main", makeCallbacks());

    dialog.show("branch");
    await vi.waitFor(() => expect(rowTexts(host).length).toBe(3));

    const rows = rowsOf(host);
    expect(rows[0]!.textContent).toBe("mainbase");
    expect(rows[0]!.querySelector(".badge")?.textContent).toBe("base");
    // The other two keep their listing order relative to each other.
    expect(rows[1]!.textContent).toBe("zeta");
    expect(rows[2]!.textContent).toBe("alpha");
  });

  it("recognizes an origin-prefixed remote-only entry as the configured base branch", async () => {
    const listRefs = vi.fn().mockResolvedValue(makeListing({ branches: ["zeta", "origin/main", "alpha"] }));
    const host = makeHost();
    const dialog = new RefSearchDialog(host, listRefs, "main", makeCallbacks());

    dialog.show("branch");
    await vi.waitFor(() => expect(rowTexts(host).length).toBe(3));

    const rows = rowsOf(host);
    expect(rows[0]!.textContent).toBe("origin/mainbase");
    expect(rows[0]!.querySelector(".badge")?.textContent).toBe("base");
    expect(rows[1]!.textContent).toBe("zeta");
    expect(rows[2]!.textContent).toBe("alpha");
  });

  it("does not badge any row when the workspace has no base branch", async () => {
    const listRefs = vi.fn().mockResolvedValue(makeListing({ branches: ["main", "feature/x"] }));
    const host = makeHost();
    const dialog = new RefSearchDialog(host, listRefs, undefined, makeCallbacks());

    dialog.show("branch");
    await vi.waitFor(() => expect(rowTexts(host).length).toBe(2));
    expect(host.querySelector(".badge")).toBeNull();
  });

  it("selects a branch by clicking its row", async () => {
    const listRefs = vi.fn().mockResolvedValue(makeListing());
    const host = makeHost();
    const callbacks = makeCallbacks();
    const dialog = new RefSearchDialog(host, listRefs, "main", callbacks);

    dialog.show("branch");
    await vi.waitFor(() => expect(rowTexts(host).length).toBeGreaterThan(0));

    rowsOf(host).find((row) => row.textContent === "feature/x")!.click();

    expect(callbacks.onSelect).toHaveBeenCalledWith("feature/x");
    expect(backdropOf(host).style.display).toBe("none");
  });
});

describe("RefSearchDialog — commit/ref mode", () => {
  it("filters commits by sha prefix", async () => {
    const listRefs = vi.fn().mockResolvedValue(makeListing());
    const host = makeHost();
    const dialog = new RefSearchDialog(host, listRefs, "main", makeCallbacks());

    dialog.show("ref");
    await vi.waitFor(() => expect(rowTexts(host).length).toBeGreaterThan(0));

    typeInto(host, "aaaaaaa");
    expect(rowTexts(host)).toEqual(["aaaaaaaFix the flaky test"]);
  });

  it("filters commits by fuzzy match over the subject", async () => {
    const listRefs = vi.fn().mockResolvedValue(makeListing());
    const host = makeHost();
    const dialog = new RefSearchDialog(host, listRefs, "main", makeCallbacks());

    dialog.show("ref");
    await vi.waitFor(() => expect(rowTexts(host).length).toBeGreaterThan(0));

    typeInto(host, "compare");
    expect(rowTexts(host)).toEqual(["bbbbbbbAdd compare menu"]);
  });

  it("offers a typed ref only after the loaded history has no match", async () => {
    const { promise, resolve } = deferred<WorkspaceRefListResult>();
    const listRefs = vi.fn().mockReturnValue(promise);
    const host = makeHost();
    const dialog = new RefSearchDialog(host, listRefs, "main", makeCallbacks());

    dialog.show("ref");
    typeInto(host, "deadbeef");
    expect(host.querySelector(".empty")?.textContent).toBe("Loading…");

    resolve(makeListing());
    await vi.waitFor(() => expect(rowTexts(host)).toEqual(["Use 'deadbeef'"]));
    expect(rowTexts(host)).toEqual(["Use 'deadbeef'"]);
  });

  it("submits the typed query verbatim (trimmed) when the 'Use' row is picked, with no client-side validation", async () => {
    const listRefs = vi.fn().mockResolvedValue(makeListing());
    const host = makeHost();
    const callbacks = makeCallbacks();
    const dialog = new RefSearchDialog(host, listRefs, "main", callbacks);

    dialog.show("ref");
    await vi.waitFor(() => expect(rowTexts(host).length).toBeGreaterThan(0));

    typeInto(host, "  not-a-real-ref  ");
    rowsOf(host)
      .find((row) => row.textContent === "Use 'not-a-real-ref'")!
      .click();

    expect(callbacks.onSelect).toHaveBeenCalledWith("not-a-real-ref");
  });

  it("selects a commit by its full sha, not its shortened display", async () => {
    const listRefs = vi.fn().mockResolvedValue(makeListing());
    const host = makeHost();
    const callbacks = makeCallbacks();
    const dialog = new RefSearchDialog(host, listRefs, "main", callbacks);

    dialog.show("ref");
    await vi.waitFor(() => expect(rowTexts(host).length).toBeGreaterThan(0));

    rowsOf(host).find((row) => row.textContent === "aaaaaaaFix the flaky test")!.click();

    expect(callbacks.onSelect).toHaveBeenCalledWith("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
  });
});

describe("RefSearchDialog — Escape and focus restore", () => {
  it("closes on Escape and restores focus to the previously focused element", async () => {
    const listRefs = vi.fn().mockResolvedValue(makeListing());
    const host = makeHost();
    const priorBtn = document.createElement("button");
    document.body.appendChild(host);
    document.body.appendChild(priorBtn);
    try {
      priorBtn.focus();
      const dialog = new RefSearchDialog(host, listRefs, "main", makeCallbacks());

      dialog.show("branch");
      expect(document.activeElement).toBe(inputOf(host));

      inputOf(host).dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));

      expect(backdropOf(host).style.display).toBe("none");
      expect(document.activeElement).toBe(priorBtn);
    } finally {
      host.remove();
      priorBtn.remove();
    }
  });

  it("a second show() while already open keeps the original prior element for restore", async () => {
    const listRefs = vi.fn().mockResolvedValue(makeListing());
    const host = makeHost();
    const priorBtn = document.createElement("button");
    document.body.appendChild(host);
    document.body.appendChild(priorBtn);
    try {
      priorBtn.focus();
      const dialog = new RefSearchDialog(host, listRefs, "main", makeCallbacks());

      dialog.show("branch");
      dialog.show("ref"); // must not overwrite priorFocusEl with the dialog's own now-focused input
      dialog.close();

      expect(document.activeElement).toBe(priorBtn);
    } finally {
      host.remove();
      priorBtn.remove();
    }
  });
});

describe("RefSearchDialog — latest-wins on reopen", () => {
  it("a slow branch-mode fetch resolving after a ref-mode reopen does not clobber the reopened state", async () => {
    const { promise: firstPromise, resolve: resolveFirst } = deferred<WorkspaceRefListResult>();
    const listRefs = vi.fn();
    listRefs.mockReturnValueOnce(firstPromise);
    const second = makeListing();
    listRefs.mockResolvedValueOnce(second);
    const host = makeHost();
    const dialog = new RefSearchDialog(host, listRefs, "main", makeCallbacks());

    dialog.show("branch");
    dialog.close();
    dialog.show("ref");
    await vi.waitFor(() => expect(rowTexts(host).length).toBeGreaterThan(0));
    // Loaded from the second (ref-mode) fetch: commit rows plus the empty-query literal is absent
    // (no query typed yet), so this is exactly the two commit rows.
    expect(rowTexts(host)).toEqual(["aaaaaaaFix the flaky test", "bbbbbbbAdd compare menu"]);

    // The stale first (branch-mode) fetch resolves after the reopen — its branches must not replace
    // the already-loaded, already-superseding ref-mode listing.
    resolveFirst(makeListing({ branches: ["should-not-appear"] }));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(rowTexts(host)).toEqual(["aaaaaaaFix the flaky test", "bbbbbbbAdd compare menu"]);
  });
});

describe("RefSearchDialog — truncation note", () => {
  it("shows a truncation note in branch mode when branchesTruncated is true", async () => {
    const listRefs = vi.fn().mockResolvedValue(makeListing({ branchesTruncated: true }));
    const host = makeHost();
    const dialog = new RefSearchDialog(host, listRefs, "main", makeCallbacks());

    dialog.show("branch");
    expect((host.querySelector(".note") as HTMLElement).hidden).toBe(true); // not yet loaded

    await vi.waitFor(() => expect((host.querySelector(".note") as HTMLElement).hidden).toBe(false));
    expect(host.querySelector(".note")!.textContent).toBe("Branch list truncated");
  });

  it("shows a truncation note in ref mode when commitsTruncated is true", async () => {
    const listRefs = vi.fn().mockResolvedValue(makeListing({ commitsTruncated: true }));
    const host = makeHost();
    const dialog = new RefSearchDialog(host, listRefs, "main", makeCallbacks());

    dialog.show("ref");
    await vi.waitFor(() => expect((host.querySelector(".note") as HTMLElement).hidden).toBe(false));
    expect(host.querySelector(".note")!.textContent).toBe("Commit history truncated");
  });

  it("hides the note when nothing is truncated", async () => {
    const listRefs = vi.fn().mockResolvedValue(makeListing());
    const host = makeHost();
    const dialog = new RefSearchDialog(host, listRefs, "main", makeCallbacks());

    dialog.show("branch");
    await vi.waitFor(() => expect(rowTexts(host).length).toBeGreaterThan(0));
    expect((host.querySelector(".note") as HTMLElement).hidden).toBe(true);
  });
});
