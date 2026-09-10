import { DiffFileEntry } from "../bridge/types";

/** Human-readable text for a submodule (gitlink) pointer: the diff's read-only placeholder row
 * (`diffView.ts`) and the Changes list chip's tooltip (`fileList.ts`) render the identical string,
 * so the two surfaces can never describe the same pointer differently. `oldCommit`/`newCommit` are full
 * 40-character shas; only the first 7 characters are shown, matching every other short-sha
 * display in this pane (e.g. `DiffFileEntry.oldSHA`/`newSHA`). One side is absent exactly when the
 * submodule was added (`oldCommit` absent) or removed (`newCommit` absent), both never absent at
 * once, since a submodule entry always has at least one side. When both sides are present and
 * identical, the pointer itself did not move (a renamed submodule, one whose own worktree is
 * dirty, or one left unresolved by a conflicting merge): a single sha is shown rather than a
 * no-op `X → X` arrow. Every flag the daemon reports is rendered, in the fixed order dirty then
 * unmerged, so this never second-guesses what the daemon observed: `dirty` and `unmerged` are
 * independent (a conflicted pointer's own worktree can also carry uncommitted edits) and both
 * suffixes can appear together. `checkedOut: false` says only that the diff did not nest this
 * submodule's own files under the pointer (never initialized, missing the comparison commit, or
 * deeper than the daemon's depth guard); it is not a statement about the checkout's condition, so a
 * readable dirty checkout sitting at the depth limit arrives as `checkedOut: false, dirty: true`
 * and keeps its "(dirty)". The ", not checked out" suffix comes last, after the parenthesised
 * flags. */
export function submoduleLabel(submodule: NonNullable<DiffFileEntry["submodule"]>): string {
  const oldShort = submodule.oldCommit?.slice(0, 7);
  const newShort = submodule.newCommit?.slice(0, 7);
  const base =
    submodule.oldCommit !== undefined && submodule.oldCommit === submodule.newCommit
      ? `Submodule ${newShort}`
      : oldShort !== undefined && newShort !== undefined
        ? `Submodule ${oldShort} → ${newShort}`
        : newShort !== undefined
          ? `Submodule added ${newShort}`
          : `Submodule removed ${oldShort}`;
  const flags = [submodule.dirty ? "dirty" : undefined, submodule.unmerged ? "unmerged" : undefined].filter(
    (flag): flag is string => flag !== undefined,
  );
  const withFlags = flags.length > 0 ? `${base} (${flags.join(", ")})` : base;
  return submodule.checkedOut ? withFlags : `${withFlags}, not checked out`;
}
