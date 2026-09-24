/**
 * Drag-resize for the Markdown split's source/preview divider. Pointer-events based, using
 * `setPointerCapture` so the drag keeps tracking when the pointer leaves the thin strip, exactly
 * like `fileListDivider.ts` does for the file list.
 *
 * Unlike that divider, this one holds a FRACTION of the split rather than a pixel width, and the
 * chosen fraction lives only as long as the Editor pane does: it is a reading posture for the
 * document in front of the user, in the same class as the mode itself (see `previewMode.ts`), not
 * a layout preference worth restoring across relaunch.
 */

/** An even split is where a document with source on one side and its rendering on the other starts. */
export const DEFAULT_EDITOR_SPLIT_FRACTION = 0.5;
/** Neither half may be squeezed past a fifth of the split: below that the narrow side stops being
 *  readable, and the user has Source or Preview for the cases where one side is all they want. */
const MIN_EDITOR_SPLIT_FRACTION = 0.2;
const MAX_EDITOR_SPLIT_FRACTION = 0.8;
/** One arrow keypress, in fraction of the split: a twentieth crosses the pane in a handful of
 *  presses while still landing a deliberate position. */
const KEYBOARD_STEP = 0.05;

export function clampEditorSplitFraction(fraction: number): number {
  if (!Number.isFinite(fraction)) return DEFAULT_EDITOR_SPLIT_FRACTION;
  return Math.min(Math.max(fraction, MIN_EDITOR_SPLIT_FRACTION), MAX_EDITOR_SPLIT_FRACTION);
}

export interface EditorSplitDividerHost {
  /** The split container the fraction is measured against. */
  container: HTMLElement;
  /** The fraction of the split the source half currently occupies. */
  fraction(): number;
  /** Records and paints a new fraction. */
  setFraction(fraction: number): void;
}

/**
 * Wires `divider` to drag and arrow-key the split. The divider is a bare div for layout reasons,
 * so separator semantics, a tab stop, and arrow-key resizing are added by hand: without them the
 * control is pointer-only for keyboard and VoiceOver users.
 */
export function attachEditorSplitDivider(divider: HTMLElement, host: EditorSplitDividerHost): void {
  divider.setAttribute("role", "separator");
  divider.setAttribute("aria-orientation", "vertical");
  divider.setAttribute("aria-label", "Resize preview");
  divider.setAttribute("aria-valuemin", String(Math.round(MIN_EDITOR_SPLIT_FRACTION * 100)));
  divider.setAttribute("aria-valuemax", String(Math.round(MAX_EDITOR_SPLIT_FRACTION * 100)));
  divider.tabIndex = 0;

  const apply = (fraction: number): void => {
    const clamped = clampEditorSplitFraction(fraction);
    host.setFraction(clamped);
    divider.setAttribute("aria-valuenow", String(Math.round(clamped * 100)));
  };
  apply(host.fraction());

  divider.addEventListener("keydown", (event) => {
    const step = event.key === "ArrowLeft" ? -KEYBOARD_STEP : event.key === "ArrowRight" ? KEYBOARD_STEP : 0;
    if (step === 0) return;
    event.preventDefault();
    apply(host.fraction() + step);
  });

  let pointerId: number | undefined;

  divider.addEventListener("pointerdown", (event) => {
    pointerId = event.pointerId;
    divider.setPointerCapture(pointerId);
    divider.classList.add("active");
    // A fast drag would otherwise select the source text the pointer crosses.
    document.body.style.userSelect = "none";
    event.preventDefault();
  });

  divider.addEventListener("pointermove", (event) => {
    if (pointerId === undefined || event.pointerId !== pointerId) return;
    const bounds = host.container.getBoundingClientRect();
    // A container with no measured width is not laid out right now, and a fraction derived from it
    // would be meaningless rather than merely imprecise.
    if (bounds.width <= 0) return;
    apply((event.clientX - bounds.left) / bounds.width);
  });

  const endDrag = (event: PointerEvent): void => {
    if (pointerId === undefined || event.pointerId !== pointerId) return;
    divider.releasePointerCapture(pointerId);
    pointerId = undefined;
    divider.classList.remove("active");
    document.body.style.userSelect = "";
  };
  divider.addEventListener("pointerup", endDrag);
  divider.addEventListener("pointercancel", endDrag);
}
