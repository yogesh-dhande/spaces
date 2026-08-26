/** Waits through two animation frames: the first lets queued DOM work commit, and the second is
 * the earliest stable browser-paint milestone shared by the diff virtualizer and editor attach. */
export function afterBrowserPaint(callback: () => void): void {
  requestAnimationFrame(() => requestAnimationFrame(callback));
}

/** Constant-time aggregate used to label scale fixtures. Git patches in the E2E matrix are ASCII,
 * so JavaScript string units equal their UTF-8 byte counts there; production Unicode patches are
 * intentionally approximate so observability never re-encodes an up-to-8 MiB result on the UI thread. */
export function aggregateContentUnits(contents: readonly (string | undefined)[]): number {
  return contents.reduce((total, content) => total + (content?.length ?? 0), 0);
}
