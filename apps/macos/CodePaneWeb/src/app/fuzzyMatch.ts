/**
 * Fuzzy subsequence matcher for the ⌘P quick-open overlay's full-listing search (see
 * `quickOpen.ts`). No third-party dependency: every query character must appear in `text` in
 * order (a subsequence match), and the score ranks a candidate higher when its matched characters
 * form consecutive runs or land on a path/word segment start (after `/`, `_`, `-`, `.`, ` `, or a
 * camelCase boundary) or inside the path's basename — the same heuristics common command-palette
 * fuzzy finders use, reimplemented small and dependency-free here.
 *
 * Matching and scoring are case-insensitive (`README.md` matches `read`), but the returned
 * `indices` are positions into the original `text`, for the caller to highlight.
 */

export interface FuzzyMatchResult {
  /** Higher is a better match. Only meaningful relative to other results for the same query. */
  score: number;
  /** Positions in `text` (not `query`) that matched, ascending, one per query character. */
  indices: number[];
}

const CONSECUTIVE_BONUS = 15;
const SEGMENT_START_BONUS = 10;
const BASENAME_BONUS = 5;

function isSeparator(ch: string): boolean {
  return ch === "/" || ch === "_" || ch === "-" || ch === "." || ch === " ";
}

/** True when `text[index]` begins a new "word": the very first character, right after a
 *  separator, or a camelCase boundary (a lowercase letter followed by an uppercase one). */
function isSegmentStart(text: string, index: number): boolean {
  if (index === 0) return true;
  const prev = text[index - 1]!;
  if (isSeparator(prev)) return true;
  const cur = text[index]!;
  return prev === prev.toLowerCase() && prev !== prev.toUpperCase() && cur === cur.toUpperCase() && cur !== cur.toLowerCase();
}

/**
 * Matches `query` as a case-insensitive subsequence of `text`, returning `null` when no such
 * subsequence exists. An empty `query` trivially matches everything with a zero score and no
 * highlighted positions — callers with a dedicated "nothing typed yet" state (the overlay's
 * recents list) don't need to route through here at all, but this keeps the function total.
 *
 * Implementation: a small forward dynamic program over `query.length * text.length` cells. Row
 * `i` (`prevRow`) holds, for every text position `p`, the best total score of matching the first
 * `i` query characters where the `i`-th character is matched exactly at `p` (or `-Infinity` when
 * no valid chain ends there). Extending to row `i+1` at position `p` picks the better of two
 * predecessors: the immediately preceding position `p-1` (a consecutive run, which gets the
 * consecutive bonus on top of whatever score matching there already had) or the best score at any
 * earlier position (a non-consecutive continuation, no bonus) — tracked via a running max as `p`
 * scans left to right, so each row is still one linear pass. Backpointers recorded alongside each
 * row let the final row's best cell reconstruct the whole match's indices.
 */
export function fuzzyMatch(query: string, text: string): FuzzyMatchResult | null {
  if (query.length === 0) return { score: 0, indices: [] };
  if (text.length === 0) return null;

  const q = query.toLowerCase();
  const t = text.toLowerCase();

  // Fast path: a single O(text.length) scan confirming `query` is a subsequence of `text` at all,
  // before the DP below allocates its rows. At the quick-open overlay's 50,000-path scale, most
  // paths share no ordered character sequence with a multi-character query, so this rejects them
  // for free and the allocation-heavy DP only ever runs on candidates that actually match.
  let qi = 0;
  for (let ti = 0; ti < t.length && qi < q.length; ti++) {
    if (t[ti] === q[qi]) qi++;
  }
  if (qi < q.length) return null;

  const basenameStart = text.lastIndexOf("/") + 1; // 0 when there is no "/"

  function positionBonus(p: number): number {
    let bonus = 0;
    if (isSegmentStart(text, p)) bonus += SEGMENT_START_BONUS;
    if (p >= basenameStart) bonus += BASENAME_BONUS;
    return bonus;
  }

  // prevRow[p] / prevBack[p] describe the row for the query character matched so far; rebuilt
  // fresh for each query character rather than kept as a 2D array, except `allBacks` (needed for
  // reconstruction) which does accumulate one row per query character.
  let prevRow = new Array<number>(text.length).fill(-Infinity);
  const allBacks: number[][] = [];

  for (let p = 0; p < text.length; p++) {
    if (t[p] !== q[0]) continue;
    prevRow[p] = 1 + positionBonus(p);
  }
  allBacks.push(new Array<number>(text.length).fill(-1)); // row 0: no predecessor, ever

  for (let i = 1; i < q.length; i++) {
    const row = new Array<number>(text.length).fill(-Infinity);
    const back = new Array<number>(text.length).fill(-1);
    let runningMax = -Infinity;
    let runningMaxPos = -1;

    for (let p = 0; p < text.length; p++) {
      if (t[p] === q[i]) {
        const consecutive = p > 0 && prevRow[p - 1]! > -Infinity ? prevRow[p - 1]! + CONSECUTIVE_BONUS : -Infinity;
        const viaGap = runningMax; // best predecessor strictly before p, already excludes p itself
        let best: number;
        let bestFrom: number;
        if (consecutive >= viaGap) {
          best = consecutive;
          bestFrom = p - 1;
        } else {
          best = viaGap;
          bestFrom = runningMaxPos;
        }
        if (best > -Infinity) {
          row[p] = best + 1 + positionBonus(p);
          back[p] = bestFrom;
        }
      }
      // Extend the running max to include position p, for the next iteration's "gap" predecessor.
      if (prevRow[p]! > runningMax) {
        runningMax = prevRow[p]!;
        runningMaxPos = p;
      }
    }

    prevRow = row;
    allBacks.push(back);
  }

  let bestScore = -Infinity;
  let bestPos = -1;
  for (let p = 0; p < text.length; p++) {
    if (prevRow[p]! > bestScore) {
      bestScore = prevRow[p]!;
      bestPos = p;
    }
  }
  if (bestPos === -1) return null;

  const indices: number[] = new Array(q.length);
  let pos = bestPos;
  for (let i = q.length - 1; i >= 0; i--) {
    indices[i] = pos;
    pos = allBacks[i]![pos]!;
  }
  return { score: bestScore, indices };
}
