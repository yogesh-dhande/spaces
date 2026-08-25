/**
 * Drag-resize for the file-list/diff-area divider (docs mockup "D — Drag divider"). Pointer-events
 * based — no drag library — using `setPointerCapture` so the drag keeps tracking even if the
 * pointer leaves the thin divider strip mid-gesture.
 */

const STORAGE_KEY = "spaces.codePane.fileListWidth";

/** Matches `.file-list`'s CSS width in app.css, which is what paints before this module's restore
 *  runs on mount (see root.ts). */
export const DEFAULT_FILE_LIST_WIDTH = 212;
const MIN_FILE_LIST_WIDTH = 160;
/** Fraction of the pane's own width the file list may grow to — half the pane, per the approved
 *  mockup, rather than an absolute cap that would mean something different on a wide vs. narrow
 *  pane. */
const MAX_FILE_LIST_WIDTH_FRACTION = 0.5;
/** Pixels one arrow keypress moves the divider — big enough to cross the list in a handful of
 *  presses, small enough to land a deliberate width. */
const KEYBOARD_RESIZE_STEP = 16;

/** Clamps a candidate file-list width to [160px, max(160px, 50% of `paneWidth`)] — the upper bound
 *  only ever loosens the floor (never drops below it) so a very narrow pane can't force a width
 *  smaller than the minimum usable list. */
export function clampFileListWidth(width: number, paneWidth: number): number {
  const max = Math.max(MIN_FILE_LIST_WIDTH, paneWidth * MAX_FILE_LIST_WIDTH_FRACTION);
  return Math.min(Math.max(width, MIN_FILE_LIST_WIDTH), max);
}

/** Reads the persisted width, or `undefined` if there is none or storage is unavailable (private
 *  browsing, quota, a WKWebView data-store restriction) — callers fall back to
 *  `DEFAULT_FILE_LIST_WIDTH` in that case, they never throw. */
export function loadStoredFileListWidth(): number | undefined {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (raw === null) return undefined;
    const parsed = Number(raw);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
  } catch {
    return undefined;
  }
}

/** Best-effort persistence only: a storage failure here just means the width resets to default next
 *  launch, not a user-visible error. */
export function storeFileListWidth(width: number): void {
  try {
    window.localStorage.setItem(STORAGE_KEY, String(width));
  } catch {
    // ignored — see doc comment above
  }
}

/**
 * Wires the file list's width lifecycle: applies the restored (or default) width immediately,
 * pointer-drag resizing on `divider`, and re-clamping against `pane`'s live width whenever the
 * pane resizes. Persists the final width on pointer-up.
 *
 * The width the user last chose (restored or dragged) is tracked separately from the width
 * actually applied — the applied width is always `clampFileListWidth(desired, paneWidth)` — so a
 * persisted-wide width restored into a narrow pane (or the pane narrowing later) can never push
 * the divider offscreen and hide the diff, and widening the pane again restores the chosen width
 * instead of ratcheting it down.
 */
export function attachFileListDivider(divider: HTMLElement, fileList: HTMLElement, pane: HTMLElement): void {
  let desiredWidth = loadStoredFileListWidth() ?? DEFAULT_FILE_LIST_WIDTH;

  // Every width application goes through here so the separator's reported value stays in sync
  // with what is actually painted.
  const applyWidth = (width: number): void => {
    fileList.style.width = `${width}px`;
    divider.setAttribute("aria-valuenow", String(Math.round(width)));
  };
  applyWidth(desiredWidth);

  // The divider is a bare div for layout reasons, so separator semantics, a tab stop, and
  // arrow-key resizing are added by hand — without them the control is pointer-only for keyboard
  // and VoiceOver users. Steps anchor on the applied width (like a drag does), so on a narrow
  // pane the keyboard adjusts what the user actually sees rather than an invisible desired width.
  divider.setAttribute("role", "separator");
  divider.setAttribute("aria-orientation", "vertical");
  divider.setAttribute("aria-label", "Resize file list");
  divider.setAttribute("aria-valuemin", String(MIN_FILE_LIST_WIDTH));
  divider.tabIndex = 0;
  divider.addEventListener("keydown", (event) => {
    const step = event.key === "ArrowLeft" ? -KEYBOARD_RESIZE_STEP : event.key === "ArrowRight" ? KEYBOARD_RESIZE_STEP : 0;
    if (step === 0) return;
    event.preventDefault();
    const applied = parseFloat(fileList.style.width) || DEFAULT_FILE_LIST_WIDTH;
    // Desired is only floor-clamped; the pane's half-width cap applies only to the painted width
    // (below). Clamping desired against the pane here would let a "wider" keypress on a clamped
    // pane silently persist a *smaller* choice than the one being restored.
    desiredWidth = Math.max(applied + step, MIN_FILE_LIST_WIDTH);
    applyWidth(clampFileListWidth(desiredWidth, pane.getBoundingClientRect().width));
    // Unlike a drag (one persist per gesture, on pointer-up), keys have no end-of-gesture event,
    // so each keypress persists.
    storeFileListWidth(desiredWidth);
  });

  new ResizeObserver((entries) => {
    const paneWidth = entries[entries.length - 1]?.contentRect.width ?? 0;
    // Zero width means the pane isn't laid out right now (e.g. editor mode has the file list
    // swapped out of the DOM) — there is nothing meaningful to clamp against, and clamping to the
    // floor here would visibly snap the list when the pane lays out again.
    if (paneWidth <= 0) return;
    // Without an explicit max, role="separator" implies aria-valuemax=100, which would make the
    // pixel-valued range invalid for assistive tech. The real ResizeObserver fires once on
    // observe, so this is also what seeds the initial max.
    divider.setAttribute(
      "aria-valuemax",
      String(Math.round(Math.max(MIN_FILE_LIST_WIDTH, paneWidth * MAX_FILE_LIST_WIDTH_FRACTION))),
    );
    applyWidth(clampFileListWidth(desiredWidth, paneWidth));
  }).observe(pane);

  let pointerId: number | undefined;
  let dragStartX = 0;
  let dragStartWidth = 0;

  divider.addEventListener("pointerdown", (event) => {
    pointerId = event.pointerId;
    dragStartX = event.clientX;
    // Read back from the inline style root.ts's mount code sets (rather than
    // `getBoundingClientRect`, which jsdom always reports as zero-sized): `fileList.style.width` is
    // always a definite px value by the time a drag can start (root.ts sets it on mount, and every
    // prior drag leaves a fresh one here).
    dragStartWidth = parseFloat(fileList.style.width) || DEFAULT_FILE_LIST_WIDTH;
    divider.setPointerCapture(pointerId);
    divider.classList.add("active");
    // A fast drag would otherwise select surrounding text/rows as the pointer crosses them.
    document.body.style.userSelect = "none";
    event.preventDefault();
  });

  divider.addEventListener("pointermove", (event) => {
    if (pointerId === undefined || event.pointerId !== pointerId) return;
    // A zero-delta move expresses no choice — updating desired from it would overwrite a wider
    // stored choice with the pane-clamped applied width the drag anchored on.
    if (event.clientX === dragStartX) return;
    // Floor-clamp only, same rationale as the keydown handler above.
    desiredWidth = Math.max(dragStartWidth + (event.clientX - dragStartX), MIN_FILE_LIST_WIDTH);
    applyWidth(clampFileListWidth(desiredWidth, pane.getBoundingClientRect().width));
  });

  const endDrag = (event: PointerEvent): void => {
    if (pointerId === undefined || event.pointerId !== pointerId) return;
    divider.releasePointerCapture(pointerId);
    pointerId = undefined;
    divider.classList.remove("active");
    document.body.style.userSelect = "";
    storeFileListWidth(desiredWidth);
  };
  divider.addEventListener("pointerup", endDrag);
  divider.addEventListener("pointercancel", endDrag);
}
