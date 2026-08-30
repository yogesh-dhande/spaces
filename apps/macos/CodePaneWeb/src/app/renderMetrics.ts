/** Waits through two animation frames: the first lets queued DOM work commit, and the second is
 * the earliest stable browser-paint milestone shared by the diff virtualizer and editor attach. */
export function afterBrowserPaint(callback: () => void): void {
  requestAnimationFrame(() => requestAnimationFrame(callback));
}

/** Awaitable counterpart used when a later transport request must not overtake a visible first
 * paint (the progressive diff manifest is deliberately held at this boundary before patch reads). */
export function browserPaint(): Promise<void> {
  return new Promise((resolve) => afterBrowserPaint(resolve));
}

/** Constant-time aggregate used to label scale fixtures. Git patches in the E2E matrix are ASCII,
 * so JavaScript string units equal their UTF-8 byte counts there; production Unicode patches are
 * intentionally approximate so observability never re-encodes uncapped per-file streamed content on
 * the UI thread. */
export function aggregateContentUnits(contents: readonly (string | undefined)[]): number {
  return contents.reduce((total, content) => total + (content?.length ?? 0), 0);
}
