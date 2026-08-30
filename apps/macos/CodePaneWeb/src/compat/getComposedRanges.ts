/**
 * Signature-compat shim for `Selection.getComposedRanges`.
 *
 * The Selection API spec changed this method's signature from variadic shadow roots
 * (`getComposedRanges(...roots)`) to an options bag (`getComposedRanges({ shadowRoots })`).
 * @pierre/diffs calls the options-bag form from its selection tracking (it runs on every
 * `selectionchange` while a CodeView is mounted), but the system WebKit on current macOS
 * releases still implements the variadic form and throws `TypeError` when handed a plain
 * object. That throw kills the editor's caret/selection tracking, so keystrokes and
 * programmatic edits inside the edit-mode contenteditable are silently dropped.
 *
 * The shim translates an options-bag call into a variadic call only when the native method
 * rejects the options bag, so it is inert on WebKit versions that already speak the new
 * signature. Installed from `main.ts` before any library code runs.
 */
export function installGetComposedRangesCompat(): void {
  const native = Selection.prototype.getComposedRanges;
  if (typeof native !== "function") return;
  Selection.prototype.getComposedRanges = function (
    this: Selection,
    ...args: unknown[]
  ): StaticRange[] {
    try {
      return native.apply(this, args as never);
    } catch (error) {
      const first = args[0] as { shadowRoots?: unknown } | undefined;
      if (
        error instanceof TypeError &&
        first !== undefined &&
        first !== null &&
        typeof first === "object" &&
        Array.isArray(first.shadowRoots)
      ) {
        return native.apply(this, first.shadowRoots as never);
      }
      throw error;
    }
  };
}
