import { PreviewMode, PreviewModeSegment } from "./previewMode";

/**
 * The open-file bar's shared segmented control for switching a file's preview mode.
 * `previewMode.ts` decides which segments exist for a file and which of them are enabled; this
 * module only renders whatever list it is given and reports clicks back to the host. `EditorView`
 * owns placing `element` in the open-file bar and deciding what `render` is called with.
 */
export class PreviewModeControl {
  /** The segmented control; the host places it in the open-file bar. */
  readonly element: HTMLElement;
  private readonly onSelect: (mode: PreviewMode) => void;

  constructor(onSelect: (mode: PreviewMode) => void) {
    this.onSelect = onSelect;
    this.element = document.createElement("div");
    this.element.className = "preview-mode-control";
    this.element.setAttribute("role", "group");
    this.element.setAttribute("aria-label", "Preview mode");
    this.element.id = "code-pane-editor-mode-control";
    // Hidden until the first render call: a file with no segments (plain text, an image) never
    // shows an empty group box in the open-file bar.
    this.element.style.display = "none";
  }

  /**
   * Renders `segments` with `selected` pressed. An empty list hides the control entirely.
   *
   * Reuses a button already on screen for a mode that appears again (updating its label,
   * `aria-pressed`, and disabled/title state in place, and repositioning it only when segment order
   * actually moved it) rather than tearing every button down and rebuilding the list from scratch.
   * Activating a segment (`EditorView.selectPreviewMode`) re-renders this control on the same tick
   * as part of repainting the pane, and that render call lands while the just-clicked or
   * -Enter-activated button still holds focus: rebuilding it as a new element, or even repositioning
   * the same node when it is already in its correct slot, would drop focus to `document.body` (a
   * DOM reposition is a remove followed by a reinsertion). Reusing the node, and touching its
   * position only when necessary, keeps the newly selected segment's button focused across that
   * repaint.
   */
  render(segments: PreviewModeSegment[], selected: PreviewMode | undefined): void {
    if (segments.length === 0) {
      this.element.textContent = "";
      this.element.style.display = "none";
      return;
    }
    this.element.style.display = "";

    const existingByMode = new Map<string, HTMLButtonElement>();
    for (const child of this.element.children) {
      const btn = child as HTMLButtonElement;
      if (btn.dataset.mode) existingByMode.set(btn.dataset.mode, btn);
    }

    let index = 0;
    for (const segment of segments) {
      let btn = existingByMode.get(segment.mode);
      if (btn) {
        existingByMode.delete(segment.mode);
      } else {
        btn = document.createElement("button");
        btn.type = "button";
        btn.className = "seg";
        btn.dataset.mode = segment.mode;
        // Reads the button's current state at click time, rather than closing over this render
        // call's `isSelected`/`enabled`, since a reused button's listener is installed once but
        // must stay correct across every later render that updates those attributes in place.
        btn.addEventListener("click", () => {
          if (btn!.disabled || btn!.getAttribute("aria-pressed") === "true") return;
          this.onSelect(segment.mode);
        });
      }
      btn.textContent = segment.label;
      btn.setAttribute("aria-pressed", String(segment.mode === selected));
      btn.disabled = !segment.enabled;
      if (!segment.enabled) {
        // A disabled segment is shown rather than omitted (see previewMode.ts's doc comment on
        // PreviewModeSegment): the title is the only place the reason ("this file isn't strict
        // JSON") is reachable, since the segment itself carries no room for explanatory text.
        btn.title = "Needs strict JSON";
      } else {
        btn.removeAttribute("title");
      }
      // Only touches the button's position when it is not already there: a still-focused button
      // this render reuses in place must never go through insertBefore/appendChild, even as a
      // same-position no-op call, since removing and reinserting a node (which is what repositioning
      // one is, even to its own spot) is what actually drops its focus to document.body.
      if (this.element.children[index] !== btn) {
        this.element.insertBefore(btn, this.element.children[index] ?? null);
      }
      index += 1;
    }

    for (const stale of existingByMode.values()) stale.remove();
  }
}
