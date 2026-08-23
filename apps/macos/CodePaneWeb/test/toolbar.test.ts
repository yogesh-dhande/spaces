import { describe, expect, it, vi } from "vitest";
import { renderToolbar, ToolbarCallbacks, ToolbarState } from "../src/app/toolbar";

function makeCallbacks(): ToolbarCallbacks {
  return { onModeChange: vi.fn(), onScopeChange: vi.fn(), onLayoutChange: vi.fn() };
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
    const state: ToolbarState = { mode: "diff", scope: { kind: "uncommitted" }, layout: "unified", baseBranch: undefined };

    renderToolbar(container, state, callbacks);

    const btn = findButton(container, "vs base branch");
    expect(btn.disabled).toBe(true);
    expect(btn.title).toBe("This workspace has no base branch configured.");
  });

  it("never invokes onScopeChange for the disabled option even if a click event reaches it", () => {
    const container = document.createElement("div");
    const callbacks = makeCallbacks();
    const state: ToolbarState = { mode: "diff", scope: { kind: "uncommitted" }, layout: "unified", baseBranch: undefined };

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
    const state: ToolbarState = { mode: "diff", scope: { kind: "uncommitted" }, layout: "unified", baseBranch: "main" };

    renderToolbar(container, state, callbacks);

    const btn = findButton(container, "vs main");
    expect(btn.disabled).toBe(false);
    btn.click();
    expect(callbacks.onScopeChange).toHaveBeenCalledWith({ kind: "baseBranch" });
  });
});
