/**
 * Resolves a reference written inside a workspace file (a Markdown image or link target) to a
 * workspace-relative path the bridge can read, or reports that it names nothing in the workspace.
 *
 * This is the only place the Markdown preview turns authored text into a path, so an image and a
 * link resolve identically: a screenshot committed next to a document and a link to the document
 * beside it are the same lookup.
 */

/** A reference with a scheme (`https:`, `mailto:`, `data:`) or a protocol-relative `//host/path`.
 *  Neither names a workspace file. */
const ABSOLUTE_REFERENCE = /^([a-zA-Z][a-zA-Z0-9+.-]*:|\/\/)/;

/**
 * Resolves `reference` as written in the file at `fromPath` (itself workspace-relative) to a
 * workspace-relative path, or `undefined` when it does not name a workspace file.
 *
 * Refused, all as "not a workspace file":
 *  - anything with a scheme or a protocol-relative prefix, which names somewhere else entirely,
 *  - a bare fragment (`#section`), which names a place in the document rather than a file,
 *  - a percent-encoding that does not decode, which names no file at all,
 *  - a path that climbs above the workspace root, which the bridge would refuse anyway.
 *
 * A leading `/` is read as workspace-root-relative rather than filesystem-absolute: inside a
 * workspace document that is the only root a reader could mean, and the bridge has no way to read
 * outside the workspace.
 *
 * A query string or fragment on an otherwise ordinary path is dropped before resolution, so
 * `diagram.png#fig-1` reads `diagram.png`.
 */
export function resolveWorkspaceReference(fromPath: string, reference: string): string | undefined {
  const trimmed = reference.trim();
  if (trimmed === "" || trimmed.startsWith("#")) return undefined;
  if (ABSOLUTE_REFERENCE.test(trimmed)) return undefined;
  const withoutSuffix = trimmed.split(/[?#]/, 1)[0] ?? "";
  if (withoutSuffix === "") return undefined;
  let decoded: string;
  try {
    decoded = decodeURIComponent(withoutSuffix);
  } catch {
    return undefined;
  }
  // A reference ending in `/`, `.`, or `..` names a directory, and a directory is not a file the
  // preview can show or the Editor can open.
  const lastSegment = decoded.split("/").at(-1);
  if (lastSegment === "" || lastSegment === "." || lastSegment === "..") return undefined;
  const base = decoded.startsWith("/") ? [] : fromPath.split("/").slice(0, -1);
  const segments = [...base, ...decoded.split("/")];
  const resolved: string[] = [];
  for (const segment of segments) {
    if (segment === "" || segment === ".") continue;
    if (segment === "..") {
      // Climbing past the workspace root is not a path the bridge could read, so it is reported the
      // same way an `https:` target is: this reference names nothing in the workspace.
      if (resolved.length === 0) return undefined;
      resolved.pop();
      continue;
    }
    resolved.push(segment);
  }
  if (resolved.length === 0) return undefined;
  return resolved.join("/");
}
