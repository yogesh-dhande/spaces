import { describe, expect, it, vi } from "vitest";
import { CodePaneAgentSummary } from "../src/bridge/types";
import { renderToolbar, ToolbarCallbacks, ToolbarState } from "../src/app/toolbar";

const AGENT_1: CodePaneAgentSummary = { id: "a1", label: "claude · main", sessionId: "s1" };
const AGENT_2: CodePaneAgentSummary = { id: "a2", label: "codex · fix-flaky-test", sessionId: "s2" };

function makeCallbacks(): ToolbarCallbacks {
  return {
    onModeChange: vi.fn(),
    onScopeChange: vi.fn(),
    onOpenRefSearch: vi.fn(),
    onLayoutChange: vi.fn(),
    onAgentSelect: vi.fn(),
    onSendBatch: vi.fn(),
  };
}

function baseState(overrides: Partial<ToolbarState> = {}): ToolbarState {
  return {
    mode: "diff",
    scope: { kind: "uncommitted" },
    layout: "unified",
    agents: [],
    selectedAgentId: undefined,
    draftCount: 0,
    ...overrides,
  };
}

function findButton(container: HTMLElement, label: string): HTMLButtonElement {
  const btn = [...container.querySelectorAll("button")].find((el) => el.textContent === label);
  if (!btn) throw new Error(`no button labeled "${label}"`);
  return btn as HTMLButtonElement;
}

function compareBtn(container: HTMLElement): HTMLButtonElement {
  const btn = container.querySelector(".compare-btn");
  if (!btn) throw new Error("no .compare-btn found");
  return btn as HTMLButtonElement;
}

function menuItems(container: HTMLElement): HTMLButtonElement[] {
  return [...container.querySelectorAll<HTMLButtonElement>(".compare-menu .item")];
}

describe("Toolbar — compare menu", () => {
  it("labels the button with the current scope: Uncommitted, Last commit, or a ref name", () => {
    const container = document.createElement("div");
    renderToolbar(container, baseState({ scope: { kind: "uncommitted" } }), makeCallbacks());
    expect(compareBtn(container).textContent).toBe("Uncommitted");

    const container2 = document.createElement("div");
    renderToolbar(container2, baseState({ scope: { kind: "lastCommit" } }), makeCallbacks());
    expect(compareBtn(container2).textContent).toBe("Last commit");

    const container3 = document.createElement("div");
    renderToolbar(container3, baseState({ scope: { kind: "ref", refName: "release/1.2" } }), makeCallbacks());
    expect(compareBtn(container3).textContent).toBe("release/1.2");
  });

  it("shortens a full 40-character sha ref name to its first 7 characters", () => {
    const container = document.createElement("div");
    const sha = "38afff17e4815ab309bf1d7ffca0787e805f7af8";
    renderToolbar(container, baseState({ scope: { kind: "ref", refName: sha } }), makeCallbacks());
    expect(compareBtn(container).textContent).toBe(sha.slice(0, 7));
  });

  it("shortens a full 64-character sha ref name to its first 7 characters", () => {
    const container = document.createElement("div");
    const sha = "38afff17e4815ab309bf1d7ffca0787e805f7af8a4667915530bc0463115518d";
    renderToolbar(container, baseState({ scope: { kind: "ref", refName: sha } }), makeCallbacks());
    expect(compareBtn(container).textContent).toBe(sha.slice(0, 7));
  });

  it("opens the menu with all four items on click, and closes it on a second click", () => {
    const container = document.createElement("div");
    renderToolbar(container, baseState(), makeCallbacks());

    expect(container.querySelector(".compare-menu")).toBeNull();
    compareBtn(container).click();
    expect(menuItems(container).map((el) => el.textContent)).toEqual([
      "Uncommitted",
      "Last commit",
      "Branch…",
      "Commit or ref…",
    ]);

    compareBtn(container).click();
    expect(container.querySelector(".compare-menu")).toBeNull();
  });

  it("marks the item matching the current scope with the 'on' class", () => {
    const container = document.createElement("div");
    renderToolbar(container, baseState({ scope: { kind: "lastCommit" } }), makeCallbacks());
    compareBtn(container).click();

    const items = menuItems(container);
    expect(items.find((el) => el.textContent === "Last commit")!.classList.contains("on")).toBe(true);
    expect(items.find((el) => el.textContent === "Uncommitted")!.classList.contains("on")).toBe(false);
  });

  it("dispatches onScopeChange and closes the menu when Uncommitted or Last commit is picked", () => {
    const container = document.createElement("div");
    const callbacks = makeCallbacks();
    renderToolbar(container, baseState({ scope: { kind: "lastCommit" } }), callbacks);

    compareBtn(container).click();
    menuItems(container).find((el) => el.textContent === "Uncommitted")!.click();

    expect(callbacks.onScopeChange).toHaveBeenCalledWith({ kind: "uncommitted" });
    expect(container.querySelector(".compare-menu")).toBeNull();
  });

  it("lists a 'vs <baseBranch>' preset between Last commit and Branch… when a base branch is configured", () => {
    const container = document.createElement("div");
    const callbacks = makeCallbacks();
    renderToolbar(container, baseState({ baseBranch: "main" }), callbacks);

    compareBtn(container).click();
    expect(menuItems(container).map((el) => el.textContent)).toEqual([
      "Uncommitted",
      "Last commit",
      "vs main",
      "Branch…",
      "Commit or ref…",
    ]);

    menuItems(container).find((el) => el.textContent === "vs main")!.click();

    expect(callbacks.onScopeChange).toHaveBeenCalledWith({ kind: "ref", refName: "main" });
    expect(container.querySelector(".compare-menu")).toBeNull();
  });

  it("marks the 'vs <baseBranch>' preset 'on' only when the current scope is a ref matching the base branch", () => {
    const container = document.createElement("div");
    renderToolbar(container, baseState({ baseBranch: "main", scope: { kind: "ref", refName: "main" } }), makeCallbacks());
    compareBtn(container).click();
    expect(menuItems(container).find((el) => el.textContent === "vs main")!.classList.contains("on")).toBe(true);

    const container2 = document.createElement("div");
    renderToolbar(
      container2,
      baseState({ baseBranch: "main", scope: { kind: "ref", refName: "release/1.2" } }),
      makeCallbacks(),
    );
    compareBtn(container2).click();
    expect(menuItems(container2).find((el) => el.textContent === "vs main")!.classList.contains("on")).toBe(false);
  });

  it("omits the 'vs <baseBranch>' preset entirely when no base branch is configured", () => {
    const container = document.createElement("div");
    renderToolbar(container, baseState(), makeCallbacks());
    compareBtn(container).click();
    expect(menuItems(container).map((el) => el.textContent)).toEqual([
      "Uncommitted",
      "Last commit",
      "Branch…",
      "Commit or ref…",
    ]);
  });

  it("calls onOpenRefSearch with 'branch' or 'ref' and closes the menu, without touching onScopeChange", () => {
    const container = document.createElement("div");
    const callbacks = makeCallbacks();
    renderToolbar(container, baseState(), callbacks);

    compareBtn(container).click();
    menuItems(container).find((el) => el.textContent === "Branch…")!.click();

    expect(callbacks.onOpenRefSearch).toHaveBeenCalledWith("branch");
    expect(callbacks.onScopeChange).not.toHaveBeenCalled();
    expect(container.querySelector(".compare-menu")).toBeNull();

    compareBtn(container).click();
    menuItems(container).find((el) => el.textContent === "Commit or ref…")!.click();

    expect(callbacks.onOpenRefSearch).toHaveBeenCalledWith("ref");
  });

  it("closes the menu on an outside click", () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    try {
      renderToolbar(container, baseState(), makeCallbacks());
      compareBtn(container).click();
      expect(container.querySelector(".compare-menu")).not.toBeNull();

      document.body.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }));
      expect(container.querySelector(".compare-menu")).toBeNull();
    } finally {
      container.remove();
    }
  });

  it("lets an outside toolbar control finish its click before closing the menu", () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    try {
      const callbacks = makeCallbacks();
      renderToolbar(container, baseState(), callbacks);
      compareBtn(container).click();

      const editorButton = findButton(container, "Editor");
      editorButton.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }));
      if (editorButton.isConnected) editorButton.click();

      expect(callbacks.onModeChange).toHaveBeenCalledWith("editor");
    } finally {
      container.remove();
    }
  });

  it("does not reopen the compare menu after leaving and returning to Diff mode", () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    try {
      let handle: ReturnType<typeof renderToolbar>;
      const callbacks = makeCallbacks();
      callbacks.onModeChange = vi.fn((mode) => handle.update(baseState({ mode })));
      handle = renderToolbar(container, baseState(), callbacks);
      compareBtn(container).click();

      findButton(container, "Editor").click();
      handle.update(baseState({ mode: "diff" }));

      expect(container.querySelector(".compare-menu")).toBeNull();
    } finally {
      container.remove();
    }
  });

  it("closes the menu on Escape", () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    try {
      renderToolbar(container, baseState(), makeCallbacks());
      compareBtn(container).click();
      expect(container.querySelector(".compare-menu")).not.toBeNull();

      window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));
      expect(container.querySelector(".compare-menu")).toBeNull();
    } finally {
      container.remove();
    }
  });
});

describe("Toolbar — compare menu keyboard focus", () => {
  // The compare button's own click handler rebuilds the toolbar (`build()` fully replaces the DOM),
  // which would otherwise destroy the focused button mid keyboard-activation (Enter/Space) and drop
  // focus to `document.body` — breaking Tab into the menu, and leaving `refSearchDialog.ts` nothing
  // real to restore focus to when it closes. These tests cover the rebuilt DOM getting focus back.

  it("focuses the first menu item when the compare button is activated with focus already on it", () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    try {
      renderToolbar(container, baseState(), makeCallbacks());
      compareBtn(container).focus();

      compareBtn(container).click();

      expect(document.activeElement).toBe(menuItems(container)[0]);
    } finally {
      container.remove();
    }
  });

  it("focuses the compare button after picking 'Branch…' from a keyboard-focused menu item", () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    try {
      const callbacks = makeCallbacks();
      renderToolbar(container, baseState(), callbacks);
      compareBtn(container).focus();
      compareBtn(container).click();

      const branchItem = menuItems(container).find((el) => el.textContent === "Branch…")!;
      branchItem.focus();
      branchItem.click();

      expect(callbacks.onOpenRefSearch).toHaveBeenCalledWith("branch");
      expect(document.activeElement).toBe(compareBtn(container));
    } finally {
      container.remove();
    }
  });

  it("returns focus to the compare button when Escape closes the menu", () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    try {
      renderToolbar(container, baseState(), makeCallbacks());
      compareBtn(container).focus();
      compareBtn(container).click();
      menuItems(container)[0]!.focus();

      window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));

      expect(document.activeElement).toBe(compareBtn(container));
    } finally {
      container.remove();
    }
  });

  it("does not steal focus on an unrelated update() when focus is outside the toolbar", () => {
    const container = document.createElement("div");
    const outsideInput = document.createElement("input");
    document.body.appendChild(container);
    document.body.appendChild(outsideInput);
    try {
      const handle = renderToolbar(container, baseState({ draftCount: 0 }), makeCallbacks());
      outsideInput.focus();
      expect(document.activeElement).toBe(outsideInput);

      handle.update(baseState({ draftCount: 1 }));

      expect(document.activeElement).toBe(outsideInput);
    } finally {
      container.remove();
      outsideInput.remove();
    }
  });

  it("preserves the focused menu item across an unrelated update()", () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    try {
      const handle = renderToolbar(container, baseState({ draftCount: 0 }), makeCallbacks());
      compareBtn(container).focus();
      compareBtn(container).click();
      const branchItem = menuItems(container).find((el) => el.textContent === "Branch…")!;
      branchItem.focus();

      handle.update(baseState({ draftCount: 1 }));

      expect(document.activeElement?.textContent).toBe("Branch…");
    } finally {
      container.remove();
    }
  });
});

describe("Toolbar — agent slot (Phase 4)", () => {
  it("renders a static label, with no <select>, when exactly one agent runs", () => {
    const container = document.createElement("div");
    const state = baseState({ agents: [AGENT_1], selectedAgentId: AGENT_1.id });

    renderToolbar(container, state, makeCallbacks());

    const label = container.querySelector(".agent-label");
    expect(label?.textContent).toBe("claude · main");
    expect(container.querySelector(".agent-select")).toBeNull();
  });

  it("renders a <select> with a disabled placeholder when more than one agent runs and none is picked", () => {
    const container = document.createElement("div");
    const state = baseState({ agents: [AGENT_1, AGENT_2], selectedAgentId: undefined });

    renderToolbar(container, state, makeCallbacks());

    const select = container.querySelector<HTMLSelectElement>(".agent-select")!;
    expect(select).not.toBeNull();
    expect(select.value).toBe(""); // the disabled placeholder option
    const options = [...select.options].map((o) => o.textContent);
    expect(options).toContain("claude · main");
    expect(options).toContain("codex · fix-flaky-test");
  });

  it("invokes onAgentSelect when a different agent is picked from the <select>", () => {
    const container = document.createElement("div");
    const callbacks = makeCallbacks();
    const state = baseState({ agents: [AGENT_1, AGENT_2], selectedAgentId: AGENT_1.id });

    renderToolbar(container, state, callbacks);

    const select = container.querySelector<HTMLSelectElement>(".agent-select")!;
    select.value = AGENT_2.id;
    select.dispatchEvent(new Event("change"));

    expect(callbacks.onAgentSelect).toHaveBeenCalledWith(AGENT_2.id);
  });

  it("disables Send batch with a no-agent reason when zero agents run", () => {
    const container = document.createElement("div");
    const state = baseState({ agents: [], selectedAgentId: undefined, draftCount: 3 });

    renderToolbar(container, state, makeCallbacks());

    const btn = findButton(container, "Send batch · 3");
    expect(btn.disabled).toBe(true);
    expect(btn.title).toBe("No agent is running in this workspace.");
  });

  it("disables Send batch with a pick-an-agent reason when agents run but none is selected", () => {
    const container = document.createElement("div");
    const state = baseState({ agents: [AGENT_1, AGENT_2], selectedAgentId: undefined, draftCount: 2 });

    renderToolbar(container, state, makeCallbacks());

    const btn = findButton(container, "Send batch · 2");
    expect(btn.disabled).toBe(true);
    expect(btn.title).toBe("Pick an agent to send to.");
  });

  it("disables Send batch with a no-comments reason when an agent is selected but there are zero drafts", () => {
    const container = document.createElement("div");
    const state = baseState({ agents: [AGENT_1], selectedAgentId: AGENT_1.id, draftCount: 0 });

    renderToolbar(container, state, makeCallbacks());

    const btn = findButton(container, "Send batch · 0");
    expect(btn.disabled).toBe(true);
    expect(btn.title).toBe("No comments to send.");
  });

  it("enables Send batch and invokes onSendBatch when an agent is selected and drafts exist", () => {
    const container = document.createElement("div");
    const callbacks = makeCallbacks();
    const state = baseState({ agents: [AGENT_1], selectedAgentId: AGENT_1.id, draftCount: 2 });

    renderToolbar(container, state, callbacks);

    const btn = findButton(container, "Send batch · 2");
    expect(btn.disabled).toBe(false);
    btn.click();
    expect(callbacks.onSendBatch).toHaveBeenCalledOnce();
  });

  it("omits the agent slot's contents entirely in Editor mode", () => {
    const container = document.createElement("div");
    const state = baseState({ mode: "editor", agents: [AGENT_1], selectedAgentId: AGENT_1.id, draftCount: 1 });

    renderToolbar(container, state, makeCallbacks());

    const slot = container.querySelector(".agent-slot");
    expect(slot?.children.length).toBe(0);
  });
});
