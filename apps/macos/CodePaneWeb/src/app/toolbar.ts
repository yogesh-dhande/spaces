import { CodePaneAgentSummary, CodePaneMode, DiffScope } from "../bridge/types";
import { DiffLayout } from "./state";

/**
 * The code pane's toolbar: Variant A ("Toolbar") from the picked mockup.
 * One 30pt `.pane-hdr` strip. The mode toggle stays visible in both modes;
 * the scope and layout segmented controls, and the assigned-agent picker
 * plus "Send batch" button, apply only to Diff mode and are omitted in
 * Editor mode (comments are diff-mode only — see reviewComments.ts).
 */
export interface ToolbarCallbacks {
  onModeChange(mode: CodePaneMode): void;
  onScopeChange(scope: DiffScope): void;
  onLayoutChange(layout: DiffLayout): void;
  onAgentSelect(id: string): void;
  onSendBatch(): void;
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
  /** Agents running in this workspace, for the assigned-agent picker. */
  agents: CodePaneAgentSummary[];
  /** `undefined` when zero agents run, or when more than one runs and none has been picked yet
   *  (see `reviewComments.ts`'s `selectDefaultAgentId`). */
  selectedAgentId: string | undefined;
  /** Count of drafts with non-empty body — what "Send batch · n" sends and shows. */
  draftCount: number;
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
 * The `.agent-slot` region's content: exactly one agent is a static label (no picking to do); more
 * than one is a `<select>`, defaulting to a disabled placeholder option until a pick is made (a
 * native `<select>` otherwise silently shows its first real option as "selected" without the
 * controller's own state agreeing one was actually chosen). "Send batch · n" is disabled, with a
 * `title` explaining why, whenever there is no agent to send to or nothing to send — the same rule
 * `commentsController.ts` applies to each card's own "Send to <label>" button.
 */
function buildAgentSlot(agentSlot: HTMLElement, state: ToolbarState, callbacks: ToolbarCallbacks): void {
  if (state.agents.length === 1) {
    const label = document.createElement("span");
    label.className = "agent-label";
    label.textContent = state.agents[0]!.label;
    agentSlot.appendChild(label);
  } else if (state.agents.length > 1) {
    const select = document.createElement("select");
    select.className = "agent-select";
    if (state.selectedAgentId === undefined) {
      const placeholder = document.createElement("option");
      placeholder.value = "";
      placeholder.textContent = "Select an agent…";
      placeholder.disabled = true;
      placeholder.selected = true;
      select.appendChild(placeholder);
    }
    for (const agent of state.agents) {
      const opt = document.createElement("option");
      opt.value = agent.id;
      opt.textContent = agent.label;
      opt.selected = agent.id === state.selectedAgentId;
      select.appendChild(opt);
    }
    select.addEventListener("change", () => callbacks.onAgentSelect(select.value));
    agentSlot.appendChild(select);
  }

  const sendBatchBtn = document.createElement("button");
  sendBatchBtn.type = "button";
  sendBatchBtn.className = "btn primary";
  sendBatchBtn.textContent = `Send batch · ${state.draftCount}`;
  const disabledReason =
    state.agents.length === 0
      ? "No agent is running in this workspace."
      : state.selectedAgentId === undefined
        ? "Pick an agent to send to."
        : state.draftCount === 0
          ? "No comments to send."
          : undefined;
  if (disabledReason !== undefined) {
    sendBatchBtn.disabled = true;
    sendBatchBtn.title = disabledReason;
  }
  sendBatchBtn.addEventListener("click", () => {
    if (sendBatchBtn.disabled) return;
    callbacks.onSendBatch();
  });
  agentSlot.appendChild(sendBatchBtn);
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
  /** round-14 Fix 2: `update()` rebuilds the toolbar wholesale on every agent-status/draft-count
   *  change (which arrive mid-typing), and replacing a focused input fires no `blur` event — these
   *  two closure vars are what carries the user's in-progress ref text and caret position across
   *  that rebuild, mirroring `commentsController.ts`'s `liveBodies` + `pendingFocus`/
   *  `captureFocusedCard` pattern for the ref input specifically. */
  let pendingRefText: string | undefined;

  function build(state: ToolbarState): void {
    // Captured before the DOM is wiped below: a focused input loses focus with no `blur` event once
    // `replaceChildren()` detaches it, so this is the only chance to notice it was mid-typing.
    const previousInput = el.querySelector("input");
    const wasRefInputFocused = previousInput !== null && previousInput === document.activeElement;
    const priorSelectionStart = wasRefInputFocused ? previousInput.selectionStart : null;
    const priorSelectionEnd = wasRefInputFocused ? previousInput.selectionEnd : null;

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
          // round-14 Fix 2: clear any leftover text from a previous open — opening the input fresh
          // should never seed it with stale in-progress text from an unrelated prior session.
          pendingRefText = undefined;
          build(state);
          // Not `refInput.querySelector(...)`: that binding is this callback's own closure, captured
          // at THIS build() invocation — build(state) above just replaced every child of `el`
          // (including that exact node) with a fresh tree, so the closed-over `refInput` is already
          // detached. `el` itself is stable across rebuilds, and build() only ever creates one
          // `<input>`, so querying `el` fresh is the only way to reach the live, now-attached one.
          el.querySelector("input")?.focus();
        }),
      );
      el.appendChild(scopeSeg);

      const refInput = document.createElement("span");
      refInput.className = "ref-input" + (refInputOpen ? " open" : "");
      const input = document.createElement("input");
      input.type = "text";
      input.placeholder = "branch or SHA";
      // round-14 Fix 2: prefer any in-progress (not-yet-committed) text over the scope's own
      // `refName` — see `pendingRefText`'s doc comment. Without this, every `update()` call while
      // the user is mid-typing (an agent-status or draft-count change, unrelated to this input)
      // would wipe whatever branch name they were typing.
      input.value = pendingRefText ?? (state.scope.kind === "ref" ? state.scope.refName : "");
      input.addEventListener("input", () => {
        pendingRefText = input.value;
      });
      input.addEventListener("keydown", (event) => {
        if (event.key === "Enter") {
          const refName = input.value.trim();
          if (refName.length > 0) {
            refInputOpen = false;
            pendingRefText = undefined;
            callbacks.onScopeChange({ kind: "ref", refName });
          }
        } else if (event.key === "Escape") {
          refInputOpen = false;
          pendingRefText = undefined;
          build(state);
        }
      });
      refInput.appendChild(input);
      el.appendChild(refInput);

      if (wasRefInputFocused) {
        // Restore focus/caret on the freshly created input — see `pendingRefText`'s doc comment for
        // why a rebuild would otherwise silently kick the user out of this field. Tried synchronously
        // first; `commentsController.ts`'s `renderCard` needs a deferred tick for the equivalent case
        // because `@pierre/diffs` inserts its returned card DOM asynchronously relative to this
        // call — this input is appended synchronously above, so the immediate attempt is expected to
        // stick, but the deferred fallback below covers it if some environment's DOM timing differs.
        input.focus();
        if (priorSelectionStart !== null && priorSelectionEnd !== null) {
          input.setSelectionRange(priorSelectionStart, priorSelectionEnd);
        }
        if (document.activeElement !== input) {
          setTimeout(() => {
            input.focus();
            if (priorSelectionStart !== null && priorSelectionEnd !== null) {
              input.setSelectionRange(priorSelectionStart, priorSelectionEnd);
            }
          }, 0);
        }
      }

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

    const agentSlot = document.createElement("span");
    agentSlot.className = "agent-slot";
    if (state.mode === "diff") {
      buildAgentSlot(agentSlot, state, callbacks);
    }
    el.appendChild(agentSlot);
  }

  build(initial);

  return {
    update(state: ToolbarState): void {
      build(state);
    },
  };
}
