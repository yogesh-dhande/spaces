/**
 * The reusable inline-text-field state machine behind the Files tree's New file / New folder /
 * Rename pointer-menu items (see `filesTree.ts` and docs/design.md's "Inline Editing"). Move to…
 * names no text of its own, so it picks a folder in an overlay instead (`folderPicker.ts`).
 * Kept independent of the tree so its commit/cancel/error/in-flight behavior is directly testable
 * without a whole tree render around it.
 */

export interface InlineRowEditRequest {
  /** The row the field takes over. Its existing children are hidden while the field is open and
   *  restored when it closes. */
  row: HTMLElement;
  initialValue: string;
  placeholder: string;
  /** Rejects with the message shown inline under the row; the field stays open so the value can be
   *  corrected. Resolving closes the editor. Called with the field's value verbatim, with no
   *  trimming of its own: a caller that compares the value against the name the row already has
   *  needs the untouched spelling, or a Return on an unchanged field for a name carrying leading or
   *  trailing whitespace would read as a change. What an empty, whitespace-only, or unchanged value
   *  means is entirely up to the caller (see `filesTree.ts`'s New file/New folder/Rename wiring, which
   *  differ on this exact point). */
  commit(value: string): Promise<void>;
  /** Runs exactly once, whichever way the editor closed. */
  onClose(): void;
}

/**
 * Mounts a text field into `request.row` in place of its current contents, wires Enter/Escape/blur,
 * and hands control back through `onClose`. Nothing here knows about files or the tree; it only
 * knows how to run one inline edit to completion.
 */
export function beginInlineRowEdit(request: InlineRowEditRequest): void {
  const { row, initialValue, placeholder, commit, onClose } = request;
  const originalChildren = [...row.childNodes];
  row.replaceChildren();

  const input = document.createElement("input");
  input.type = "text";
  input.className = "inline-name";
  input.placeholder = placeholder;
  input.value = initialValue;
  row.appendChild(input);

  let closed = false;
  let errorEl: HTMLElement | undefined;

  const clearError = (): void => {
    errorEl?.remove();
    errorEl = undefined;
  };

  const showError = (message: string): void => {
    clearError();
    errorEl = document.createElement("div");
    errorEl.className = "inline-error";
    // Not a descendant of `row` (it sits right after it, so it never gets swept up by `close()`'s
    // `replaceChildren`), so it needs its own copy of the row's indent custom property.
    const depth = row.style.getPropertyValue("--depth");
    if (depth) errorEl.style.setProperty("--depth", depth);
    errorEl.textContent = message;
    row.insertAdjacentElement("afterend", errorEl);
  };

  const close = (): void => {
    if (closed) return;
    closed = true;
    clearError();
    row.replaceChildren(...originalChildren);
    onClose();
  };

  const attemptCommit = (): void => {
    if (input.disabled) return; // a commit is already in flight; see the disabled guard below
    clearError();
    input.disabled = true;
    commit(input.value).then(
      () => close(),
      (err: unknown) => {
        if (closed) return; // the field was closed (e.g. Escape) before this settled
        input.disabled = false;
        showError(err instanceof Error ? err.message : String(err));
        input.focus();
      },
    );
  };

  // The row this field takes over keeps all of its own listeners (see `filesTree.ts`'s file and
  // directory rows: click/keydown to open or toggle, contextmenu to open the pointer menu). Those
  // listeners are attached to the row, so every event the field raises would bubble straight into
  // them: Space would be swallowed by the row's own `preventDefault`, Enter would commit AND then
  // open/toggle the row behind the field, and a right-click meant for the field's native editing
  // menu would open the tree's menu instead. Stopping propagation at the field is what keeps an open
  // edit self-contained; it is done for every pointer and key event the row listens for, not only
  // the ones the tree happens to bind today.
  for (const type of ["keydown", "keyup", "mousedown", "click", "dblclick", "contextmenu"]) {
    input.addEventListener(type, (event) => event.stopPropagation());
  }

  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      attemptCommit();
    } else if (event.key === "Escape") {
      event.preventDefault();
      close();
    }
  });
  input.addEventListener("blur", () => {
    // Disabling a focused input blurs it as a side effect (see `attemptCommit`'s `input.disabled =
    // true`); that blur must not race the in-flight commit's own close()/re-enable, or a successful
    // commit's close() would run twice (harmless, guarded by `closed`) but a rejection would land on
    // a field this handler already tried to tear down.
    if (input.disabled) return;
    close();
  });

  input.focus();
  input.select();
}
