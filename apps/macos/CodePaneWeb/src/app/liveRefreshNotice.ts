/**
 * Persistent corner banner shown while the daemon's file watcher for this workspace is down, so
 * the Diff and Files streams have stopped recomputing on git-state changes (see
 * `docs/implementation.md`'s event-gated refresh section). Follows `docs/design.md`'s persistent-
 * banner pattern: it outlines itself in the orange state tint, never covers content, and carries
 * the one recovery action (Retry) a broken watcher has. Unlike a transient banner it has no
 * dismiss affordance: it clears only when a stream reports a clean frame again.
 *
 * A pane has one banner (docs/design.md): a transient banner (`editorView.ts`'s and
 * `commentsController.ts`'s own `.banner`, `diffView.ts`'s `.banner.error` edit-error banner)
 * overrides this persistent one while it is up, and this one reappears once the transient banner
 * clears. `attachTo` is what makes that hold without any of those three owners knowing this module
 * exists: it appends `el` into the given container and watches that container with a
 * `MutationObserver` for the `style` changes those banners toggle their own visibility through, so
 * `render()` can hide this notice whenever any `.banner` under the container is showing
 * (`style.display` other than `"none"`). root.ts owns all other state (which reason to show,
 * whether a retry is in flight) and calls `attachTo` again on every mode switch to move `el`
 * between the Diff pane's content area and the Editor's; this module only renders whatever it is
 * told, restricted to whichever container it was last attached to.
 */
export interface LiveRefreshNoticeHandle {
  el: HTMLElement;
  /** Moves `el` into `container` and starts watching it for transient-banner visibility changes,
   *  replacing whatever container (and observer) this handle was previously attached to. */
  attachTo(container: HTMLElement): void;
  /** Shows the banner with `reason` (the daemon's error text, verbatim) and wires `onRetry` to the
   *  Retry button. Safe to call repeatedly (e.g. on every push frame that still carries an error);
   *  does not touch the retrying/disabled state (see `setRetrying`). */
  show(reason: string, onRetry: () => void): void;
  hide(): void;
  /** Toggles the Retry button between "Retry" and a disabled "Retrying…", for the span between a
   *  click and the next push frame from either signature stream. */
  setRetrying(retrying: boolean): void;
}

export function createLiveRefreshNotice(): LiveRefreshNoticeHandle {
  const el = document.createElement("div");
  el.id = "code-pane-live-refresh-notice";
  el.className = "live-refresh-notice";
  el.hidden = true;
  // Only the Retry button below takes clicks; a click anywhere else on the banner (or beside it)
  // must reach the content underneath, per docs/design.md's persistent-banner rule.
  el.style.pointerEvents = "none";

  const label = document.createElement("span");
  label.className = "live-refresh-notice-label";
  el.appendChild(label);

  const retryButton = document.createElement("button");
  retryButton.type = "button";
  retryButton.className = "live-refresh-notice-retry";
  retryButton.textContent = "Retry";
  retryButton.style.pointerEvents = "auto";
  el.appendChild(retryButton);

  let onRetry: (() => void) | undefined;
  retryButton.addEventListener("click", () => onRetry?.());

  // `visible` is root.ts's own want (a stream currently carries an error); `render()` additionally
  // withholds it whenever a transient banner is up in the attached container, per the one-banner
  // rule above. Neither `show`/`hide` nor the observer callback touch `el.hidden` directly, so the
  // two conditions can never race each other into a wrong answer.
  let visible = false;
  let container: HTMLElement | undefined;
  let observer: MutationObserver | undefined;

  function transientBannerIsUp(): boolean {
    if (container === undefined) return false;
    for (const banner of container.querySelectorAll<HTMLElement>(".banner")) {
      if (banner.style.display !== "none") return true;
    }
    return false;
  }

  function render(): void {
    el.hidden = !visible || transientBannerIsUp();
  }

  return {
    el,
    attachTo(nextContainer) {
      observer?.disconnect();
      container = nextContainer;
      nextContainer.appendChild(el);
      observer = new MutationObserver(render);
      observer.observe(nextContainer, { subtree: true, attributes: true, attributeFilter: ["style"], childList: true });
      render();
    },
    show(reason, retryHandler) {
      label.textContent = `Live refresh off: ${reason}`;
      onRetry = retryHandler;
      visible = true;
      render();
    },
    hide() {
      visible = false;
      onRetry = undefined;
      render();
    },
    setRetrying(retrying) {
      retryButton.disabled = retrying;
      retryButton.textContent = retrying ? "Retrying…" : "Retry";
    },
  };
}
