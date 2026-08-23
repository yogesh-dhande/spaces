import { describe, expect, it, vi } from "vitest";
import { CodePaneAgentSummary } from "../src/bridge/types";
import { renderToolbar, ToolbarCallbacks, ToolbarState } from "../src/app/toolbar";

const AGENT_1: CodePaneAgentSummary = { id: "a1", label: "claude · main", sessionId: "s1" };
const AGENT_2: CodePaneAgentSummary = { id: "a2", label: "codex · fix-flaky-test", sessionId: "s2" };

function makeCallbacks(): ToolbarCallbacks {
  return { onModeChange: vi.fn(), onScopeChange: vi.fn(), onLayoutChange: vi.fn(), onAgentSelect: vi.fn(), onSendBatch: vi.fn() };
}

function baseState(overrides: Partial<ToolbarState> = {}): ToolbarState {
  return {
    mode: "diff",
    scope: { kind: "uncommitted" },
    layout: "unified",
    baseBranch: undefined,
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

// Round-4 Fix 5: a workspace with no base branch must not offer a scope option
// `CodePaneBridge.refName(for:)` is guaranteed to reject.
describe("Toolbar — base-branch scope availability (round-4 Fix 5)", () => {
  it("disables the option and gives it an explanatory title when the workspace has no base branch", () => {
    const container = document.createElement("div");
    const callbacks = makeCallbacks();
    const state = baseState({ baseBranch: undefined });

    renderToolbar(container, state, callbacks);

    const btn = findButton(container, "vs base branch");
    expect(btn.disabled).toBe(true);
    expect(btn.title).toBe("This workspace has no base branch configured.");
  });

  it("never invokes onScopeChange for the disabled option even if a click event reaches it", () => {
    const container = document.createElement("div");
    const callbacks = makeCallbacks();
    const state = baseState({ baseBranch: undefined });

    renderToolbar(container, state, callbacks);

    const btn = findButton(container, "vs base branch");
    // `.click()` is suppressed by jsdom for a disabled button, mirroring real browsers; dispatching
    // the event directly bypasses that suppression, standing in for "somehow activated" despite the
    // disabled attribute — the segButton listener's own `if (btn.disabled) return` guard is what
    // must stop it from here.
    btn.dispatchEvent(new MouseEvent("click", { bubbles: true }));

    expect(callbacks.onScopeChange).not.toHaveBeenCalled();
  });

  it("enables the option and labels it with the branch name when the workspace has one", () => {
    const container = document.createElement("div");
    const callbacks = makeCallbacks();
    const state = baseState({ baseBranch: "main" });

    renderToolbar(container, state, callbacks);

    const btn = findButton(container, "vs main");
    expect(btn.disabled).toBe(false);
    btn.click();
    expect(callbacks.onScopeChange).toHaveBeenCalledWith({ kind: "baseBranch" });
  });
});

describe("Toolbar — 'vs ref…' focuses the live input after rebuild (round-8 Fix 4)", () => {
  it("focuses the input that is actually in the document, not a detached node from the pre-click render", () => {
    // jsdom only tracks `document.activeElement` for a node connected to the document — a detached
    // container's `.focus()` calls are silently inert — so this container (unlike this file's other
    // tests, which don't care about focus) has to be attached to `document.body` for the assertion
    // below to mean anything.
    const container = document.createElement("div");
    document.body.appendChild(container);
    try {
      const callbacks = makeCallbacks();
      const state = baseState({ baseBranch: "main" });

      renderToolbar(container, state, callbacks);
      const btn = findButton(container, "vs ref…");
      btn.click(); // opens the ref input, rebuilding the toolbar's children in the process

      const liveInput = container.querySelector("input");
      expect(liveInput).not.toBeNull();
      expect(document.activeElement).toBe(liveInput);
    } finally {
      container.remove();
    }
  });
});

describe("Toolbar — pending 'vs ref' text survives a wholesale rebuild (round-14 Fix 2)", () => {
  it("keeps the ref input open with the typed text, focus, and caret preserved across update()", () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    try {
      const callbacks = makeCallbacks();
      const state = baseState({ baseBranch: "main", agents: [AGENT_1], selectedAgentId: AGENT_1.id, draftCount: 0 });

      const { update } = renderToolbar(container, state, callbacks);
      findButton(container, "vs ref…").click(); // opens the ref input, focusing it

      const input = container.querySelector("input")!;
      input.value = "feature/partial-ty";
      input.dispatchEvent(new Event("input"));
      input.setSelectionRange(7, 7); // caret in the middle of "feature/|partial-ty"

      // A mid-typing agent/draft-count change, unrelated to the ref input, must not wipe it out —
      // `update()` rebuilds the toolbar wholesale on every such change.
      update(baseState({ baseBranch: "main", agents: [AGENT_1, AGENT_2], selectedAgentId: AGENT_2.id, draftCount: 3 }));

      const rebuiltInput = container.querySelector("input")!;
      expect(rebuiltInput.value).toBe("feature/partial-ty");
      expect(document.activeElement).toBe(rebuiltInput);
      expect(rebuiltInput.selectionStart).toBe(7);
      expect(rebuiltInput.selectionEnd).toBe(7);
    } finally {
      container.remove();
    }
  });

  it("closes the ref input on Escape and does not resurface the stale text the next time it's opened", () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    try {
      const callbacks = makeCallbacks();
      const state = baseState({ baseBranch: "main" });

      const { update } = renderToolbar(container, state, callbacks);
      findButton(container, "vs ref…").click();

      const input = container.querySelector("input")!;
      input.value = "abandoned-branch";
      input.dispatchEvent(new Event("input"));
      input.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));

      update(baseState({ baseBranch: "main" }));
      expect(container.querySelector(".ref-input.open")).toBeNull();

      // Re-opening must start blank, not resurface "abandoned-branch" from the closed session.
      findButton(container, "vs ref…").click();
      expect(container.querySelector("input")!.value).toBe("");
    } finally {
      container.remove();
    }
  });

  it("still commits the typed ref exactly as before on Enter (regression check)", () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    try {
      const callbacks = makeCallbacks();
      const state = baseState({ baseBranch: "main" });

      renderToolbar(container, state, callbacks);
      findButton(container, "vs ref…").click();

      const input = container.querySelector("input")!;
      input.value = "release/1.2";
      input.dispatchEvent(new Event("input"));
      input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter" }));

      expect(callbacks.onScopeChange).toHaveBeenCalledWith({ kind: "ref", refName: "release/1.2" });
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
