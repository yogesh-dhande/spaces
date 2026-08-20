import Foundation

/// Ghostty drains its pending render scroll rects on every snapshot export (fork-side
/// `clearPendingRenderScrollRects`), self-contained or not. A `.selfContained` export (a one-shot
/// state read, e.g. serving a Device API `.state` request) forces a full render update, and a full
/// update never carries scroll rects, so a one-shot read silently discards whatever movement Ghostty
/// had queued. A stream subscriber mid-drag needs to see every bit of scroll movement between two of
/// its own deltas, including movement a one-shot read happened to drain in between, or its mirrored
/// selection carry falls out of sync with the real screen.
///
/// This type is the fix: a self-contained export folds its drained rects in here instead of letting
/// them vanish, and the next `.streamDeltaAllowed` export drains the carry and prepends it (older
/// movement first) to whatever rects it captured itself. The carry is reset to empty on every drain,
/// so it only ever holds movement consumed since the last stream export.
public struct TerminalStreamScrollRectCarry: Sendable {
    /// Rects folded in beyond this bound would make the carry an unbounded backlog if no
    /// `.streamDeltaAllowed` export ever runs (e.g. no subscriber attached) while one-shot reads keep
    /// arriving. Past the bound the carry gives up on carrying exact rects and instead poisons itself:
    /// it clears its storage and reports `overflowed`, the same signal Ghostty's own ring uses when it
    /// wraps, so the next stream delta falls back to a full frame instead of trusting a partial carry.
    public static let maxCarriedRects = 128

    public private(set) var rects: [GhosttyRenderScrollRectOperation] = []
    public private(set) var overflowed = false

    public init() {}

    /// Folds a one-shot export's drained rects into the carry, appending after whatever is already
    /// stored so replay order stays oldest-first. `overflowed` only ever turns true, matching the
    /// poison semantics above.
    public mutating func fold(rects newRects: [GhosttyRenderScrollRectOperation], overflowed newOverflowed: Bool) {
        if newOverflowed { overflowed = true }
        guard !newRects.isEmpty else { return }
        if rects.count + newRects.count > Self.maxCarriedRects {
            rects = []
            overflowed = true
            return
        }
        rects.append(contentsOf: newRects)
    }

    /// Drains the carry for a stream export: the carried rects come first (older), followed by the
    /// rects this export captured itself, with the overflow flag ORed from both sides. Resets the
    /// carry to empty/false so the next stream export starts clean.
    public mutating func drain(mergingWith rects: [GhosttyRenderScrollRectOperation], overflowed: Bool) -> (
        rects: [GhosttyRenderScrollRectOperation], overflowed: Bool
    ) {
        let mergedRects = self.rects + rects
        let mergedOverflowed = self.overflowed || overflowed
        self.rects = []
        self.overflowed = false
        return (mergedRects, mergedOverflowed)
    }
}
