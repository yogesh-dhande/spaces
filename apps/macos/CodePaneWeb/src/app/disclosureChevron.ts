/**
 * The disclosure slot both file lists' rows lead with: `filesTree.ts`'s Files tree and
 * `fileList.ts`'s Changes list. A directory with something to disclose gets the chevron; every other
 * row gets the same slot left empty, so a file name starts in the same column as a sibling folder's
 * label instead of hanging one glyph to its left.
 */

/** Points right; `app.css` turns it a quarter turn down through the `.tri.open` class the row's own
 *  expanded state sets, so the rotation is a transition rather than a swapped glyph. */
const CHEVRON_SVG =
  '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 3.5 10.5 8 6 12.5"/></svg>';

/** The chevron slot for a directory row that can be expanded. The glyph is decorative: the row
 *  itself carries the `role="button"`/`aria-expanded` pair that reports the disclosure state, so the
 *  svg is hidden from assistive technology. */
export function createDisclosureChevron(): HTMLElement {
  const tri = document.createElement("span");
  tri.className = "tri";
  tri.innerHTML = CHEVRON_SVG;
  return tri;
}

/** The same slot, empty, for a row with nothing to disclose: a file row, or a directory row with no
 *  children (a submodule checkout holding no listable file, an empty directory). */
export function createDisclosureSpacer(): HTMLElement {
  const tri = document.createElement("span");
  tri.className = "tri";
  return tri;
}

/** Points the chevron down while `expanded`, right otherwise. Safe on a spacer, which has no glyph
 *  to turn. */
export function setDisclosureExpanded(tri: HTMLElement, expanded: boolean): void {
  tri.classList.toggle("open", expanded);
}
