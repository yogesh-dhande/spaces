import { CodePaneAgentSummary, CodePaneMode, DiffScope } from "../bridge/types";
import { RefSearchMode } from "./refSearchDialog";
import { DiffLayout } from "./state";

/**
 * The code pane's toolbar: Variant A ("Toolbar") from the picked mockup.
 * One 30pt `.pane-hdr` strip. The mode toggle stays visible in both modes;
 * the compare menu and layout segmented control, and the assigned-agent
 * picker plus "Send batch" button, apply only to Diff mode and are omitted
 * in Editor mode (comments are diff-mode only — see reviewComments.ts).
 */
export interface ToolbarCallbacks {
  onModeChange(mode: CodePaneMode): void;
  onScopeChange(scope: DiffScope): void;
  /** The configured-base preset was picked. The owner resolves its stored short name against the
   *  workspace's current refs before dispatching the scope (remote-only branches are listed as
   *  `origin/<name>`). */
  onBaseBranchSelect(baseBranch: string): void;
  /** "Branch…" or "Commit or ref…" was picked from the compare menu — the caller opens
   *  `refSearchDialog.ts` in the corresponding mode. Unlike `onScopeChange`, this never changes
   *  `ToolbarState` itself (the dialog's own eventual pick does, via `onScopeChange`), so the
   *  toolbar closes its own menu immediately rather than waiting on a state update to do it. */
  onOpenRefSearch(mode: RefSearchMode): void;
  onLayoutChange(layout: DiffLayout): void;
  onAgentSelect(id: string): void;
  onStartAgent(): void;
  onSendBatch(): void;
}

export interface ToolbarState {
  mode: CodePaneMode;
  scope: DiffScope;
  layout: DiffLayout;
  /** The workspace's configured base branch name, absent when it has none — same source as
   *  `CodePaneInitPayload.baseBranch` (fixed for the pane's lifetime). Drives the compare menu's
   *  "vs <baseBranch>" preset, which is omitted entirely (not disabled) when this is absent. */
  baseBranch?: string;
  /** The exact ref selected by the configured-base preset, if that preset owns the current scope.
   *  This is separate from `baseBranch` because a manually selected `origin/<baseBranch>` is not
   *  the preset when a local base ref is also available. */
  baseBranchRefName?: string;
  /** Agents running in this workspace, for the assigned-agent picker. */
  agents: CodePaneAgentSummary[];
  /** `undefined` when zero agents run, or when more than one runs and none has been picked yet
   *  (see `reviewComments.ts`'s `selectDefaultAgentId`). */
  selectedAgentId: string | undefined;
  /** A command has launched but agent hooks have not reported a running session yet. */
  agentStarting?: boolean;
  /** Count of drafts with non-empty body — what "Send batch · n" sends and shows. */
  draftCount: number;
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
    if (btn.disabled) return;
    onClick();
  });
  return btn;
}

const FULL_OBJECT_ID_PATTERN = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/i;

/** The compare button's own label for the current scope: the scope name for `uncommitted` and
 *  `lastCommit`, or the ref name for `kind: "ref"` — shortened to 7 characters when it's a full
 *  SHA-1 or SHA-256 object id (a typed branch/tag name is shown in full). */
function compareLabel(scope: DiffScope): string {
  if (scope.kind === "uncommitted") return "Uncommitted";
  if (scope.kind === "lastCommit") return "Last commit";
  return FULL_OBJECT_ID_PATTERN.test(scope.refName) ? scope.refName.slice(0, 7) : scope.refName;
}

function menuItem(label: string, isOn: boolean, onClick: () => void): HTMLButtonElement {
  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "item" + (isOn ? " on" : "");
  btn.textContent = label;
  btn.addEventListener("click", onClick);
  return btn;
}

/**
 * The `.agent-slot` has one compact assignment control: Start agent with no sessions, a running
 * agent selector otherwise, or a temporary Starting agent label while a command is detected. The
 * launch state replaces only that control; the independent Send batch action remains available to
 * an already assigned running agent. A disabled assignment or empty batch explains itself with a
 * title, matching `commentsController.ts`'s per-card send rule.
 */
function buildAgentSlot(agentSlot: HTMLElement, state: ToolbarState, callbacks: ToolbarCallbacks): void {
  if (state.agentStarting) {
    const starting = document.createElement("span");
    starting.className = "agent-label";
    starting.textContent = "Starting agent…";
    agentSlot.appendChild(starting);
  } else if (state.agents.length === 0) {
    const start = document.createElement("button");
    start.type = "button";
    start.className = "btn";
    start.id = "code-pane-start-agent";
    start.textContent = "Start agent…";
    start.addEventListener("click", callbacks.onStartAgent);
    agentSlot.appendChild(start);
  } else {
    const select = document.createElement("select");
    select.className = "agent-select";
    select.id = "code-pane-agent-selector";
    if (state.selectedAgentId === undefined) {
      const placeholder = document.createElement("option");
      placeholder.value = "";
      placeholder.textContent = "Assign agent…";
      placeholder.disabled = true;
      placeholder.selected = true;
      select.appendChild(placeholder);
    }
    for (const agent of state.agents) {
      const opt = document.createElement("option");
      opt.value = agent.id;
      opt.textContent = agent.id === state.selectedAgentId ? `Send to: ${agent.label}` : agent.label;
      opt.selected = agent.id === state.selectedAgentId;
      select.appendChild(opt);
    }
    const separator = document.createElement("option");
    separator.disabled = true;
    separator.textContent = "────────";
    select.appendChild(separator);
    const startNew = document.createElement("option");
    startNew.value = "__start_new_agent__";
    startNew.textContent = "Start new…";
    select.appendChild(startNew);
    select.addEventListener("change", () => {
      if (select.value === "__start_new_agent__") {
        // Opening and then cancelling the command dialog must not leave this transient menu
        // sentinel visually selected. Restore the durable assignment (or its placeholder) before
        // the dialog takes focus; no toolbar render is required to repair it later.
        select.value = state.selectedAgentId ?? "";
        callbacks.onStartAgent();
      } else {
        callbacks.onAgentSelect(select.value);
      }
    });
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

  /** Whether the compare dropdown is open — a closure var (not part of `ToolbarState`) so it
   *  survives an unrelated `update()` rebuild (agent-status/draft-count changes arrive independently
   *  of the menu), the same reason `refInputOpen` used to persist this way before the compare menu
   *  replaced the inline ref input. */
  let compareMenuOpen = false;
  /** Removes the previous build's outside-click/Escape listeners, if any were registered. `build()`
   *  fully replaces the DOM on every call (`replaceChildren`), so a listener attached to `window`
   *  during one build would otherwise leak and pile up across rebuilds instead of being torn down
   *  along with the detached elements it closed over. */
  let disposeMenuListeners: (() => void) | undefined;
  let lastState: ToolbarState = initial;

  /** Where to move focus after the rebuild `build()` is about to do, set by whichever call site is
   *  toggling the menu open or closed. `build()` consumes and clears this, and only ever acts on it
   *  when focus was inside `el` going into the rebuild — an unrelated `update()` (e.g. draft-count
   *  changes) never sets this, so it can never steal focus from elsewhere in the page. */
  let pendingFocus: "menuItem" | "compareBtn" | undefined;

  function closeCompareMenu(): void {
    compareMenuOpen = false;
    // The menu-item click handlers below call this before invoking their own callback (see
    // `onOpenRefSearch`'s doc comment), so focusing the compare button here — rather than leaving
    // focus wherever the now-removed menu item was — is also what gives `refSearchDialog.ts` a real
    // `priorFocusEl` to restore to when it closes.
    pendingFocus = "compareBtn";
    build(lastState);
  }

  function build(state: ToolbarState): void {
    lastState = state;
    if (state.mode !== "diff") compareMenuOpen = false;
    // `replaceChildren()` below destroys whatever was focused inside `el` (e.g. the compare button
    // itself, mid keyboard-activation). Captured before the removal, so a menu-open/close rebuild can
    // restore focus to its rebuilt equivalent instead of stranding it on `document.body`.
    const priorActive = document.activeElement;
    const shouldRestoreFocus = el.contains(priorActive);
    const priorMenuItems = [...el.querySelectorAll<HTMLButtonElement>(".compare-menu .item")];
    const priorMenuItemIndex = priorActive instanceof HTMLButtonElement ? priorMenuItems.indexOf(priorActive) : -1;
    const focusIntent = pendingFocus;
    pendingFocus = undefined;
    disposeMenuListeners?.();
    disposeMenuListeners = undefined;
    el.replaceChildren();

    // Diff | Editor — visible in both modes.
    const modeSeg = document.createElement("span");
    modeSeg.className = "seg";
    const diffMode = segButton("Diff", state.mode === "diff", () => callbacks.onModeChange("diff"));
    diffMode.id = "code-pane-mode-diff";
    const editorMode = segButton("Editor", state.mode === "editor", () => callbacks.onModeChange("editor"));
    editorMode.id = "code-pane-mode-editor";
    modeSeg.append(diffMode, editorMode);
    el.appendChild(modeSeg);

    if (state.mode === "diff") {
      const kind = state.scope.kind;

      const compareWrap = document.createElement("span");
      compareWrap.className = "compare";

      const compareBtn = document.createElement("button");
      compareBtn.type = "button";
      compareBtn.className = "compare-btn";
      compareBtn.id = "code-pane-scope-menu";
      compareBtn.textContent = compareLabel(state.scope);
      compareBtn.addEventListener("click", () => {
        compareMenuOpen = !compareMenuOpen;
        pendingFocus = compareMenuOpen ? "menuItem" : "compareBtn";
        build(state);
      });
      compareWrap.appendChild(compareBtn);

      if (compareMenuOpen) {
        const menu = document.createElement("div");
        menu.className = "compare-menu";

        const uncommitted = menuItem("Uncommitted", kind === "uncommitted", () => {
          closeCompareMenu();
          callbacks.onScopeChange({ kind: "uncommitted" });
        });
        uncommitted.id = "code-pane-scope-uncommitted";
        menu.appendChild(uncommitted);
        const lastCommit = menuItem("Last commit", kind === "lastCommit", () => {
            closeCompareMenu();
            callbacks.onScopeChange({ kind: "lastCommit" });
          });
        lastCommit.id = "code-pane-scope-last-commit";
        menu.appendChild(lastCommit);
        if (state.baseBranch !== undefined) {
          const baseBranch = state.baseBranch;
          menu.appendChild(
            menuItem(
              `vs ${baseBranch}`,
              kind === "ref" && state.scope.refName === state.baseBranchRefName,
              () => {
                closeCompareMenu();
                callbacks.onBaseBranchSelect(baseBranch);
              },
            ),
          );
        }
        menu.appendChild(
          menuItem("Branch…", false, () => {
            closeCompareMenu();
            callbacks.onOpenRefSearch("branch");
          }),
        );
        menu.appendChild(
          menuItem("Commit or ref…", false, () => {
            closeCompareMenu();
            callbacks.onOpenRefSearch("ref");
          }),
        );
        compareWrap.appendChild(menu);

        const onMousedown = (event: MouseEvent): void => {
          if (compareWrap.contains(event.target as Node)) return;
          // An outside press may be targeting another toolbar control. Remove only the dropdown so
          // that control remains connected long enough to receive the matching click.
          compareMenuOpen = false;
          menu.remove();
          disposeMenuListeners?.();
          disposeMenuListeners = undefined;
        };
        const onKeydown = (event: KeyboardEvent): void => {
          if (event.key === "Escape") closeCompareMenu();
        };
        window.addEventListener("mousedown", onMousedown);
        window.addEventListener("keydown", onKeydown);
        disposeMenuListeners = () => {
          window.removeEventListener("mousedown", onMousedown);
          window.removeEventListener("keydown", onKeydown);
        };
      }

      el.appendChild(compareWrap);

      const layoutSeg = document.createElement("span");
      layoutSeg.className = "seg";
      const split = segButton("Split", state.layout === "split", () => callbacks.onLayoutChange("split"));
      split.id = "code-pane-layout-split";
      layoutSeg.appendChild(split);
      const unified = segButton("Unified", state.layout === "unified", () => callbacks.onLayoutChange("unified"));
      unified.id = "code-pane-layout-unified";
      layoutSeg.appendChild(unified);
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

    if (shouldRestoreFocus && focusIntent === "menuItem") {
      el.querySelector<HTMLButtonElement>(".compare-menu .item")?.focus();
    } else if (shouldRestoreFocus && focusIntent === "compareBtn") {
      el.querySelector<HTMLButtonElement>(".compare-btn")?.focus();
    } else if (shouldRestoreFocus && priorMenuItemIndex >= 0) {
      const rebuiltMenuItems = [...el.querySelectorAll<HTMLButtonElement>(".compare-menu .item")];
      rebuiltMenuItems[Math.min(priorMenuItemIndex, rebuiltMenuItems.length - 1)]?.focus();
    }
  }

  build(initial);

  return {
    update(state: ToolbarState): void {
      build(state);
    },
  };
}
