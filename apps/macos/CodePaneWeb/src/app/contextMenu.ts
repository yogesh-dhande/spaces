/**
 * The pane's own in-page context menu: a small floating list positioned at the pointer and clamped
 * inside its host, used where WebKit's native menu carries nothing useful (a right-click on a
 * rendered diff line — see `DiffView`'s `contextmenu` handler).
 *
 * One instance is mounted on the pane root (not on the diff's scrolling area) so the menu is never
 * clipped by, or scrolled with, the region the click landed in.
 */

export interface ContextMenuItem {
  label: string;
  onSelect(): void;
}

export interface ContextMenuRequest {
  /** Viewport coordinates of the pointer, i.e. a `MouseEvent`'s `clientX`/`clientY`. */
  x: number;
  y: number;
  /** Muted, non-interactive first line naming what the items act on. */
  header?: string;
  items: readonly ContextMenuItem[];
}

export interface ContextMenu {
  show(request: ContextMenuRequest): void;
  hide(): void;
  isOpen(): boolean;
}

export function createContextMenu(host: HTMLElement): ContextMenu {
  const el = document.createElement("div");
  el.className = "ctx-menu";
  el.setAttribute("role", "menu");
  let items: HTMLButtonElement[] = [];
  let previouslyFocused: HTMLElement | undefined;
  let dispose: (() => void) | undefined;

  function isOpen(): boolean {
    return el.isConnected;
  }

  function hide(): void {
    if (!isOpen()) return;
    // Hand focus back only while the menu still holds it. A dismissal caused by focus moving to
    // another surface (the `focusin` handler below) must leave that surface, Quick Open's input for
    // one, as the owner of the keyboard rather than pulling focus back to where the menu began.
    const focusIsInMenu = el.contains(document.activeElement);
    dispose?.();
    dispose = undefined;
    el.remove();
    items = [];
    const restore = previouslyFocused;
    previouslyFocused = undefined;
    if (focusIsInMenu && restore?.isConnected === true) restore.focus();
  }

  function focusItem(index: number): void {
    if (items.length === 0) return;
    const wrapped = (index + items.length) % items.length;
    items[wrapped]!.focus();
  }

  function activate(item: ContextMenuItem): void {
    // Close first so focus is handed back before the action runs: an action that moves focus itself
    // (opening a file in the editor) must not have it taken away again by the restore.
    hide();
    item.onSelect();
  }

  function show(request: ContextMenuRequest): void {
    hide();
    previouslyFocused = document.activeElement instanceof HTMLElement ? document.activeElement : undefined;

    el.replaceChildren();
    if (request.header !== undefined) {
      const head = document.createElement("div");
      head.className = "head";
      head.textContent = request.header;
      el.appendChild(head);
    }
    items = request.items.map((item) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "item";
      button.setAttribute("role", "menuitem");
      button.textContent = item.label;
      button.addEventListener("click", () => activate(item));
      el.appendChild(button);
      return button;
    });

    // Positioned after mounting: the clamp needs the menu's real measured size.
    el.style.left = "0px";
    el.style.top = "0px";
    host.appendChild(el);
    const hostRect = host.getBoundingClientRect();
    const menuRect = el.getBoundingClientRect();
    el.style.left = `${Math.max(0, Math.min(request.x - hostRect.left, hostRect.width - menuRect.width))}px`;
    el.style.top = `${Math.max(0, Math.min(request.y - hostRect.top, hostRect.height - menuRect.height))}px`;

    const onKeydown = (event: KeyboardEvent): void => {
      if (event.key === "Escape") {
        event.preventDefault();
        hide();
        return;
      }
      const focusedIndex = items.findIndex((item) => item === document.activeElement);
      if (event.key === "ArrowDown") {
        event.preventDefault();
        focusItem(focusedIndex + 1);
      } else if (event.key === "ArrowUp") {
        event.preventDefault();
        focusItem(focusedIndex - 1);
      } else if (event.key === "Enter" || event.key === " ") {
        if (focusedIndex < 0) return;
        // Also suppresses the click a browser would synthesize for the focused button, which would
        // otherwise run the item a second time.
        event.preventDefault();
        activate(request.items[focusedIndex]!);
      }
    };
    const onMousedown = (event: MouseEvent): void => {
      if (!event.composedPath().includes(el)) hide();
    };
    // Focus leaving the menu for another surface (⌘P's Quick Open input, the ref search) means
    // that surface owns the keyboard now; the capture-phase keydown handler above must not keep
    // steering arrows and Enter back into a menu the user has moved past.
    const onFocusin = (event: FocusEvent): void => {
      if (!event.composedPath().includes(el)) hide();
    };
    const onScroll = (): void => hide();
    const onBlur = (): void => hide();
    const onResize = (): void => hide();
    document.addEventListener("keydown", onKeydown, true);
    document.addEventListener("mousedown", onMousedown, true);
    document.addEventListener("focusin", onFocusin, true);
    // Capture phase: a scroll event does not bubble, so this is the only way one instance can see
    // scrolling in the region the menu is anchored over.
    document.addEventListener("scroll", onScroll, true);
    window.addEventListener("blur", onBlur);
    window.addEventListener("resize", onResize);
    dispose = () => {
      document.removeEventListener("keydown", onKeydown, true);
      document.removeEventListener("mousedown", onMousedown, true);
      document.removeEventListener("focusin", onFocusin, true);
      document.removeEventListener("scroll", onScroll, true);
      window.removeEventListener("blur", onBlur);
      window.removeEventListener("resize", onResize);
    };

    focusItem(0);
  }

  return { show, hide, isOpen };
}
