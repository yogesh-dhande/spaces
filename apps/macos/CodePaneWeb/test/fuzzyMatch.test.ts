import { describe, expect, it } from "vitest";
import { fuzzyMatch } from "../src/app/fuzzyMatch";

describe("fuzzyMatch", () => {
  it("returns a zero-score, no-indices match for an empty query against any text", () => {
    expect(fuzzyMatch("", "src/app/root.ts")).toEqual({ score: 0, indices: [] });
    expect(fuzzyMatch("", "")).toEqual({ score: 0, indices: [] });
  });

  it("returns null for an empty text with a non-empty query", () => {
    expect(fuzzyMatch("a", "")).toBeNull();
  });

  it("returns null when query is not a subsequence of text", () => {
    expect(fuzzyMatch("xyz", "README.md")).toBeNull();
    // "z" never appears at all.
    expect(fuzzyMatch("readmez", "README.md")).toBeNull();
  });

  it("returns null via the fast subsequence pre-check for a long non-matching text", () => {
    // Exercises the O(text.length) scan's own early-return path (not just the DP's), on an input
    // long enough that only the fast path would notice quickly.
    const text = "a".repeat(10_000) + "b";
    expect(fuzzyMatch("ba", text)).toBeNull();
  });

  it("matches case-insensitively but reports indices into the original text", () => {
    const result = fuzzyMatch("read", "README.md");
    expect(result).not.toBeNull();
    expect(result!.indices).toEqual([0, 1, 2, 3]);
  });

  it("matches a non-contiguous subsequence, indices ascending and one per query character", () => {
    // "rtm" as a subsequence of "root.ts" -> r(0) o o t(3) . t s -> picks r=0, t=3, ... "m" isn't
    // in "root.ts" at all, so use a query that genuinely is a subsequence instead.
    const result = fuzzyMatch("rts", "root.ts");
    expect(result).not.toBeNull();
    expect(result!.indices).toHaveLength(3);
    // Ascending and each position actually holds the matched character.
    const idx = result!.indices;
    expect(idx[0]! < idx[1]!).toBe(true);
    expect(idx[1]! < idx[2]!).toBe(true);
    expect("root.ts"[idx[0]!]!.toLowerCase()).toBe("r");
    expect("root.ts"[idx[1]!]!.toLowerCase()).toBe("t");
    expect("root.ts"[idx[2]!]!.toLowerCase()).toBe("s");
  });

  it("scores a fully consecutive run higher than the same characters scattered apart", () => {
    const consecutive = fuzzyMatch("root", "root.ts");
    const scattered = fuzzyMatch("root", "r-o-o-t.ts");
    expect(consecutive).not.toBeNull();
    expect(scattered).not.toBeNull();
    expect(consecutive!.score).toBeGreaterThan(scattered!.score);
  });

  it("scores a match starting at a path segment boundary higher than one starting mid-segment", () => {
    // "app" matches at a true segment start in "src/app/index.ts" (right after "/"), and also
    // matches contiguously but mid-word inside "src/mapper/index.ts" (the "app" in "mapper") —
    // same depth, same basename, isolating the segment-start bonus as the only difference.
    const atSegmentStart = fuzzyMatch("app", "src/app/index.ts");
    const midSegment = fuzzyMatch("app", "src/mapper/index.ts");
    expect(atSegmentStart).not.toBeNull();
    expect(midSegment).not.toBeNull();
    expect(atSegmentStart!.score).toBeGreaterThan(midSegment!.score);
  });

  it("scores a match inside the basename higher than the identical characters earlier in the path", () => {
    // "root" appears as a directory segment early in the path and again as the basename; the
    // dynamic program picks whichever chain scores highest, and the basename occurrence gets the
    // basename bonus on top of the same consecutive/segment-start bonuses, so matching there wins.
    const result = fuzzyMatch("root", "root/nested/root.ts");
    expect(result).not.toBeNull();
    const basenameStart = "root/nested/root.ts".lastIndexOf("/") + 1;
    expect(result!.indices[0]).toBeGreaterThanOrEqual(basenameStart);
  });

  it("treats a camelCase boundary as a segment start", () => {
    // "vc" matches "viewController.ts" either as v(0) + the "c" inside "view", or as v(0) + the
    // "C" beginning "Controller" — a genuine camelCase segment start — which should score higher.
    const atBoundary = fuzzyMatch("vc", "viewController.ts");
    expect(atBoundary).not.toBeNull();
    // Index 4 is the "C" in "viewController.ts" (v-i-e-w-C...), the camelCase boundary.
    expect(atBoundary!.indices).toEqual([0, 4]);
  });
});
