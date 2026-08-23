import { CodePaneMode, DiffScope } from "../bridge/types";
import { DiffLayout } from "./state";

/**
 * The code pane's toolbar: Variant A ("Toolbar") from the picked mockup.
 * One 30pt `.pane-hdr` strip. The mode toggle stays visible in both modes;
 * the scope and layout segmented controls apply only to Diff mode and are
 * omitted in Editor mode. The trailing region is reserved for Phase 4's
 * assigned-agent dropdown and "Send batch" button — it renders nothing here.
 */
export interface ToolbarCallbacks {
  onModeChange(mode: CodePaneMode): void;
  onScopeChange(scope: DiffScope): void;
  onLayoutChange(layout: DiffLayout): void;
}

export interface ToolbarState {
  mode: CodePaneMode;
  scope: DiffScope;
  layout: DiffLayout;
  /** The workspace's base branch name, absent when it has none. Absence disables the "vs base
   *  branch" scope option below rather than hiding it — `CodePaneBridge.refName(for:)` rejects that
   *  scope outright when the workspace has no base branch configured, so leaving the option enabled
   *  would offer a guaranteed-to-fail choice. */
  baseBranch: string | undefined;
}

function scopeSegmentKind(scope: DiffScope): "uncommitted" | "baseBranch" | "ref" {
  return scope.kind;
}

interface SegButtonOptions {
  disabled?: boolean;
  title?: string;
}

function segButton(label: string, isOn: boolean, onClick: () => void, options?: SegButtonOptions): HTMLButtonElement {
  const btn = document.createElement("button");
  btn.type = "button";
  btn.textContent = label;
  if (isOn) btn.classList.add("on");
  if (options?.disabled) btn.disabled = true;
  if (options?.title) btn.title = options.title;
  btn.addEventListener("click", () => {
    // A disabled button doesn't dispatch a click natively, but guard explicitly too: this is the
    // only place a disabled segment's callback could still fire from, so it's the one place that
    // needs to enforce it rather than relying on every caller remembering to check `state.baseBranch`.
    if (btn.disabled) return;
    onClick();
  });
  return btn;
}

/**
 * Renders the toolbar into `container` and returns an `update` function to
 * re-render when state changes (mode/scope/layout can all change from
 * outside the toolbar too, e.g. a future keyboard shortcut).
 */
export function renderToolbar(
  container: HTMLElement,
  initial: ToolbarState,
  callbacks: ToolbarCallbacks,
): { update(state: ToolbarState): void } {
  const el = document.createElement("div");
  el.className = "pane-hdr";
  container.appendChild(el);

  let refInputOpen = false;

  function build(state: ToolbarState): void {
    el.replaceChildren();

    // Diff | Editor — visible in both modes.
    const modeSeg = document.createElement("span");
    modeSeg.className = "seg";
    modeSeg.appendChild(segButton("Diff", state.mode === "diff", () => callbacks.onModeChange("diff")));
    modeSeg.appendChild(segButton("Editor", state.mode === "editor", () => callbacks.onModeChange("editor")));
    el.appendChild(modeSeg);

    if (state.mode === "diff") {
      const kind = scopeSegmentKind(state.scope);

      const scopeSeg = document.createElement("span");
      scopeSeg.className = "seg";
      scopeSeg.appendChild(
        segButton("Uncommitted", kind === "uncommitted", () => callbacks.onScopeChange({ kind: "uncommitted" })),
      );
      scopeSeg.appendChild(
        segButton(state.baseBranch ? `vs ${state.baseBranch}` : "vs base branch", kind === "baseBranch",
          () => callbacks.onScopeChange({ kind: "baseBranch" }),
          state.baseBranch === undefined
            ? { disabled: true, title: "This workspace has no base branch configured." }
            : undefined,
        ),
      );
      scopeSeg.appendChild(
        segButton("vs ref…", kind === "ref", () => {
          refInputOpen = true;
          build(state);
          refInput.querySelector("input")?.focus();
        }),
      );
      el.appendChild(scopeSeg);

      const refInput = document.createElement("span");
      refInput.className = "ref-input" + (refInputOpen ? " open" : "");
      const input = document.createElement("input");
      input.type = "text";
      input.placeholder = "branch or SHA";
      input.value = state.scope.kind === "ref" ? state.scope.refName : "";
      input.addEventListener("keydown", (event) => {
        if (event.key === "Enter") {
          const refName = input.value.trim();
          if (refName.length > 0) {
            refInputOpen = false;
            callbacks.onScopeChange({ kind: "ref", refName });
          }
        } else if (event.key === "Escape") {
          refInputOpen = false;
          build(state);
        }
      });
      refInput.appendChild(input);
      el.appendChild(refInput);

      const layoutSeg = document.createElement("span");
      layoutSeg.className = "seg";
      layoutSeg.appendChild(segButton("Split", state.layout === "split", () => callbacks.onLayoutChange("split")));
      layoutSeg.appendChild(
        segButton("Unified", state.layout === "unified", () => callbacks.onLayoutChange("unified")),
      );
      el.appendChild(layoutSeg);
    }

    const spacer = document.createElement("span");
    spacer.className = "sp";
    el.appendChild(spacer);

    // Reserved for Phase 4 (assigned-agent dropdown + "Send batch · n").
    const agentSlot = document.createElement("span");
    agentSlot.className = "agent-slot";
    el.appendChild(agentSlot);
  }

  build(initial);

  return {
    update(state: ToolbarState): void {
      build(state);
    },
  };
}
