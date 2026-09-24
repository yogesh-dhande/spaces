/**
 * The centered floating picker both the ⌘P quick-open overlay (`quickOpen.ts`) and the Files tree's
 * Move to… folder picker (`folderPicker.ts`) are built from: the backdrop/panel/title/field/list
 * shell, the type-to-filter + arrow-key + Return + Escape keyboard model, the focus restore that
 * hands the keyboard back to whatever the overlay opened on top of, and the `<mark>` highlighting of
 * a fuzzy match's matched characters. An owner supplies only the rows for the text currently in the
 * field and what choosing one does, so the two pickers cannot drift apart on any of the above.
 *
 * `refSearchDialog.ts` predates this and still builds its own shell; it shares this module's
 * `renderHighlighted` and the `.quick-open` styles, which is where its overlap actually is.
 */

export interface PickerRow {
  /** What the row shows, with every position in `indices` marked; also the row's `data-path`. */
  text: string;
  /** Matched character positions into `text`, from `fuzzyMatch`; empty when nothing is typed. */
  indices: readonly number[];
  /** A muted trailing badge, such as the folder an item being moved already sits in. */
  badge?: string;
  /** False for a row the arrow keys skip and Return ignores: it is listed for orientation rather
   *  than as something to pick. */
  selectable: boolean;
}

export interface PickerContent<R extends PickerRow> {
  rows: readonly R[];
  /** A quiet uppercase heading above the rows (⌘P's "Recent"); absent when they need none. */
  sectionLabel?: string;
  /** Shown in place of an empty list. */
  emptyText: string;
  /** A footer line under the list (⌘P's truncation note); absent when there is nothing to say. */
  note?: string;
}

export interface PickerOverlayConfig {
  /** The panel's classes. Every picker is a `.quick-open` panel; a variant adds one class of its
   *  own for the row shapes it introduces (see app.css). */
  panelClass: string;
  /** The stem every element id here is built from: the listbox is `<prefix>-list` (named by the
   *  field's `aria-controls`), the field `<prefix>-input`, the empty state `<prefix>-empty`, and a
   *  row `<prefix>-<its text,
   *  percent-encoded>` (named by `aria-activedescendant`). Row ids are derived from the text rather
   *  than from a position so a row keeps one identifier as the list filters around it; the macOS
   *  e2e suite addresses quick-open rows by exactly these. */
  idPrefix: string;
  placeholder: string;
}

export interface PickerOverlayCallbacks<R extends PickerRow> {
  /** The rows to show for the field's current text. Called on open, on every keystroke, and from
   *  `refresh()`. */
  content(query: string): PickerContent<R>;
  /** A selectable row was picked with Return or a click; the overlay has already closed and handed
   *  focus back, so an action that moves focus itself naturally wins. */
  choose(row: R): void;
}

/**
 * The `PickerOverlay` currently on screen, if any: shared module state rather than something each
 * instance tracks about its siblings, since exactly one `CodePaneWeb` page (`main.ts`'s `mountRoot`)
 * ever runs per document, so one slot is enough to make "only one of these overlays at a time" hold
 * across the whole page. `show()` reads and writes it to close whatever else is open before opening
 * itself, which is what keeps ⌘P quick-open and the Files tree's Move to… folder picker (the two
 * owners built on this class) from ever stacking: opening one always closes the other first, the
 * same way Escape would, cancelling whatever it had in progress (a pending move, a filtered search)
 * and handing focus back to what it was opened on top of. Typed by the one method a sibling instance
 * ever needs to call on another, not by `PickerOverlay<R>`, since a shared slot can't name every
 * owner's own row shape.
 */
let openOverlay: { close(): void } | undefined;

export class PickerOverlay<R extends PickerRow> {
  private readonly backdropEl: HTMLElement;
  private readonly titleEl: HTMLElement;
  private readonly inputEl: HTMLInputElement;
  private readonly listEl: HTMLElement;
  private readonly noteEl: HTMLElement;

  private open = false;
  private rows: readonly R[] = [];
  private rowEls: HTMLElement[] = [];
  /** Index into `rows` of the highlighted row, or -1 when no row can be picked (an empty list, or
   *  one holding nothing but unselectable rows). */
  private selectedIndex = -1;
  /** Whatever had focus just before `show()` moved it to the field, so `close()` can restore it:
   *  otherwise the hidden field (or, if it was never focused, nothing) strands focus at `<body>` and
   *  keystrokes stop reaching the editor textarea or the keyboard-operable tree row the overlay was
   *  opened on top of, until the user clicks something. `undefined` when nothing needs restoring
   *  (nothing was focused, or this overlay's own field was; see `show()`'s already-open guard). */
  private priorFocusEl: HTMLElement | undefined;

  constructor(
    host: HTMLElement,
    private readonly config: PickerOverlayConfig,
    private readonly callbacks: PickerOverlayCallbacks<R>,
  ) {
    this.backdropEl = document.createElement("div");
    this.backdropEl.className = "quick-open-backdrop";
    this.backdropEl.style.display = "none";
    // Only a click landing directly on the backdrop (not bubbled up from the panel) dismisses;
    // the panel's own mousedown listener below stops that bubbling.
    this.backdropEl.addEventListener("mousedown", (event) => {
      if (event.target === this.backdropEl) this.close();
    });

    const panel = document.createElement("div");
    panel.className = config.panelClass;
    panel.addEventListener("mousedown", (event) => event.stopPropagation());

    this.titleEl = document.createElement("div");
    this.titleEl.className = "title";
    this.titleEl.hidden = true;

    this.inputEl = document.createElement("input");
    this.inputEl.type = "text";
    this.inputEl.id = `${config.idPrefix}-input`;
    this.inputEl.setAttribute("role", "combobox");
    this.inputEl.setAttribute("aria-controls", `${config.idPrefix}-list`);
    this.inputEl.setAttribute("aria-expanded", "true");
    this.inputEl.setAttribute("aria-autocomplete", "list");
    this.inputEl.placeholder = config.placeholder;
    this.inputEl.addEventListener("input", () => this.renderContent(true));
    this.inputEl.addEventListener("keydown", (event) => this.handleKeydown(event));

    this.listEl = document.createElement("div");
    this.listEl.className = "list";
    this.listEl.id = `${config.idPrefix}-list`;
    this.listEl.setAttribute("role", "listbox");

    this.noteEl = document.createElement("div");
    this.noteEl.className = "note";
    this.noteEl.hidden = true;

    panel.appendChild(this.titleEl);
    panel.appendChild(this.inputEl);
    panel.appendChild(this.listEl);
    panel.appendChild(this.noteEl);
    this.backdropEl.appendChild(panel);
    host.appendChild(this.backdropEl);
  }

  isOpen(): boolean {
    return this.open;
  }

  /** Opens with an empty field and the first selectable row highlighted. `title` is a line above the
   *  field naming what the picker acts on, or `undefined` for a picker whose placeholder says it. */
  show(title: Node | undefined): void {
    // Guard against a second open while already open: this overlay's own field is what has focus in
    // that case, so capturing now would overwrite the real prior element with it.
    if (!this.open) {
      // Closed before this one opens, not after: this overlay's own field is about to take focus
      // below, so the other owner's close() (which restores focus to whatever it was opened on top
      // of) has to run first, or its restored focus would just be stolen right back. Closing it this
      // way also runs its own cancellation, exactly as if the user had pressed Escape on it; a
      // folder picker closed out from under it by a Quick Open still owns nothing, so its pending
      // move never fires.
      if (openOverlay !== undefined && openOverlay !== this) openOverlay.close();
      const active = document.activeElement;
      this.priorFocusEl = active instanceof HTMLElement && active !== this.inputEl ? active : undefined;
    }
    this.open = true;
    openOverlay = this;
    this.titleEl.hidden = title === undefined;
    this.titleEl.replaceChildren(...(title === undefined ? [] : [title]));
    this.inputEl.value = "";
    this.backdropEl.style.display = "flex";
    this.renderContent(true);
    this.inputEl.focus();
  }

  close(): void {
    this.open = false;
    if (openOverlay === this) openOverlay = undefined;
    this.backdropEl.style.display = "none";
    // Restored only while the element is still connected: the underlying element (a since-removed
    // tree row, say) may be gone by now.
    if (this.priorFocusEl?.isConnected) this.priorFocusEl.focus();
    this.priorFocusEl = undefined;
  }

  /** Re-runs `content()` against the field's current text, keeping the highlight where it is rather
   *  than resetting it. The owner calls this when the data behind the rows changes underneath an
   *  open overlay (⌘P's listing revalidation); a no-op while closed, since the next `show()` renders
   *  from scratch anyway. */
  refresh(): void {
    if (!this.open) return;
    this.renderContent(false);
  }

  private handleKeydown(event: KeyboardEvent): void {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      this.moveSelection(event.key === "ArrowDown" ? 1 : -1);
      return;
    }
    if (event.key === "Enter") {
      event.preventDefault();
      const row = this.rows[this.selectedIndex];
      if (row?.selectable === true) {
        this.close();
        this.callbacks.choose(row);
      }
      return;
    }
    if (event.key === "Escape") {
      event.preventDefault();
      this.close();
    }
  }

  /** Moves the highlight to the next selectable row in `delta`'s direction, or leaves it where it is
   *  when there is none: an unselectable row is skipped over rather than landed on. */
  private moveSelection(delta: number): void {
    for (let index = this.selectedIndex + delta; index >= 0 && index < this.rows.length; index += delta) {
      if (this.rows[index]!.selectable) {
        this.selectedIndex = index;
        this.highlightSelection();
        return;
      }
    }
  }

  /** Recomputes the rows for the field's current text and repaints the list. `resetSelection` is the
   *  difference between a keystroke (the highlight goes back to the top) and a data change under an
   *  open overlay (the highlight stays where the user put it, clamped back into range). */
  private renderContent(resetSelection: boolean): void {
    const content = this.callbacks.content(this.inputEl.value);
    this.rows = content.rows;
    const from = resetSelection ? 0 : Math.max(0, Math.min(this.selectedIndex, this.rows.length - 1));
    this.selectedIndex = this.nearestSelectable(from);
    this.renderRows(content);
  }

  /** The selectable row at or after `from`, else the nearest one before it, else -1. */
  private nearestSelectable(from: number): number {
    for (let index = from; index < this.rows.length; index++) if (this.rows[index]!.selectable) return index;
    for (let index = Math.min(from, this.rows.length) - 1; index >= 0; index--) if (this.rows[index]!.selectable) return index;
    return -1;
  }

  private renderRows(content: PickerContent<R>): void {
    this.listEl.replaceChildren();
    this.rowEls = [];

    this.noteEl.hidden = content.note === undefined;
    if (content.note !== undefined) this.noteEl.textContent = content.note;

    if (this.rows.length === 0) {
      this.inputEl.removeAttribute("aria-activedescendant");
      const empty = document.createElement("div");
      empty.className = "empty";
      empty.id = `${this.config.idPrefix}-empty`;
      empty.textContent = content.emptyText;
      this.listEl.appendChild(empty);
      return;
    }

    if (content.sectionLabel !== undefined) {
      const label = document.createElement("div");
      label.className = "section-label";
      label.textContent = content.sectionLabel;
      this.listEl.appendChild(label);
    }

    for (const row of this.rows) {
      const rowEl = document.createElement("div");
      rowEl.className = "row";
      rowEl.setAttribute("role", "option");
      rowEl.id = `${this.config.idPrefix}-${encodeURIComponent(row.text)}`;
      rowEl.dataset.path = row.text;
      const textEl = document.createElement("span");
      textEl.className = "path";
      textEl.appendChild(renderHighlighted(row.text, row.indices));
      textEl.title = row.text;
      rowEl.appendChild(textEl);
      if (row.badge !== undefined) {
        const badge = document.createElement("span");
        badge.className = "badge";
        badge.textContent = row.badge;
        rowEl.appendChild(badge);
      }
      if (row.selectable) {
        rowEl.addEventListener("click", () => {
          this.close();
          this.callbacks.choose(row);
        });
      } else {
        rowEl.classList.add("unselectable");
        rowEl.setAttribute("aria-disabled", "true");
      }
      this.listEl.appendChild(rowEl);
      this.rowEls.push(rowEl);
    }
    this.highlightSelection();
  }

  private highlightSelection(): void {
    this.rowEls.forEach((rowEl, index) => {
      const isSelected = index === this.selectedIndex;
      rowEl.classList.toggle("sel", isSelected);
      rowEl.setAttribute("aria-selected", String(isSelected));
      if (isSelected) rowEl.scrollIntoView({ block: "nearest" });
    });
    const selected = this.rowEls[this.selectedIndex];
    if (selected) this.inputEl.setAttribute("aria-activedescendant", selected.id);
    else this.inputEl.removeAttribute("aria-activedescendant");
  }
}

/** Builds `text` as a fragment with every position in `indices` wrapped in a `<mark>`, coalescing
 *  adjacent matched (or unmatched) runs into single nodes rather than one node per character. */
export function renderHighlighted(text: string, indices: readonly number[]): DocumentFragment {
  const frag = document.createDocumentFragment();
  const matched = new Set(indices);
  let buf = "";
  let bufIsMatch = false;
  const flush = (): void => {
    if (!buf) return;
    if (bufIsMatch) {
      const mark = document.createElement("mark");
      mark.textContent = buf;
      frag.appendChild(mark);
    } else {
      frag.appendChild(document.createTextNode(buf));
    }
    buf = "";
  };
  for (let i = 0; i < text.length; i++) {
    const isMatch = matched.has(i);
    if (buf && isMatch !== bufIsMatch) flush();
    bufIsMatch = isMatch;
    buf += text[i];
  }
  flush();
  return frag;
}
