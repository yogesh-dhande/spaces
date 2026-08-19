import spacesterminalcore

/// Pure, MainActor-free helpers for translating between the shared-selection/scroll-rect wire model
/// (`GhosttyTerminalSnapshot`, `GhosttyRenderScrollRectOperation`) and the GhosttyKit C frame fields the
/// mirror surface actually reads (`ghostty_terminal_snapshot_s`'s `selection_flags`/`scrollbar_*`/
/// `scroll_rects`/`scroll_carry_valid`, and `ghostty_mirror_selection_info_s`'s signed rows). Split out
/// from `GhosttyMirrorTerminalView` so this arithmetic is testable without a live surface, a window, or
/// the main actor.
enum GhosttyMirrorSelectionMarshalling {
    /// Bit layout `ghostty_terminal_snapshot_s.selection_flags` expects: bit 0 present, bit 1 rectangle,
    /// bit 2 extends_above, bit 3 extends_below.
    static let selectionFlagPresent: UInt8 = 1 << 0
    static let selectionFlagRectangle: UInt8 = 1 << 1
    static let selectionFlagExtendsAbove: UInt8 = 1 << 2
    static let selectionFlagExtendsBelow: UInt8 = 1 << 3

    /// The subset of `ghostty_terminal_snapshot_s`'s fields this feature adds, as a plain value so the
    /// mapping from a Swift snapshot can be unit tested without touching the C struct or an unsafe
    /// pointer.
    struct CSnapshotSelectionFields: Equatable {
        var selectionFlags: UInt8
        var selectionStartX: UInt16
        var selectionStartY: UInt16
        var selectionEndX: UInt16
        var selectionEndY: UInt16
        var scrollbarTotal: UInt32
        var scrollbarOffset: UInt32
    }

    /// Maps a snapshot's shared selection and scrollbar position onto the C struct fields. A nil
    /// selection clears every selection field (flags 0), which the surface reads as "nothing to paint."
    static func cSnapshotSelectionFields(
        selection: GhosttyTerminalSelectionRange?, scrollbarTotal: UInt32, scrollbarOffset: UInt32
    ) -> CSnapshotSelectionFields {
        var flags: UInt8 = 0
        var startX: UInt16 = 0
        var startY: UInt16 = 0
        var endX: UInt16 = 0
        var endY: UInt16 = 0
        if let selection {
            flags |= selectionFlagPresent
            if selection.isRectangle { flags |= selectionFlagRectangle }
            if selection.extendsAbove { flags |= selectionFlagExtendsAbove }
            if selection.extendsBelow { flags |= selectionFlagExtendsBelow }
            startX = selection.startColumn
            startY = selection.startRow
            endX = selection.endColumn
            endY = selection.endRow
        }
        return CSnapshotSelectionFields(
            selectionFlags: flags, selectionStartX: startX, selectionStartY: startY, selectionEndX: endX, selectionEndY: endY,
            scrollbarTotal: scrollbarTotal, scrollbarOffset: scrollbarOffset)
    }

    /// Accumulates scroll rects across frames the mirror has not yet successfully applied, so a
    /// drag-carry anchored before a skipped or retried frame still has the full path once the mirror
    /// catches up. Poisoned by any frame that is not a delta continuation (a fresh baseline, a
    /// re-baseline, or a resync) or whose own delta's scroll-rect ring buffer overflowed: both report
    /// through the same `scrollRectsOverflowed` flag on `GhosttyRenderFrame`, because "everything moved
    /// and I can't say how" and "something moved that I have no rect for" are the same situation for a
    /// consumer trying to carry a local anchor across the gap. Neither can be trusted, and guessing is
    /// worse than cancelling the drag.
    struct ScrollRectCarryBuffer: Equatable {
        /// Upper bound on accumulated rects. A view that cannot apply frames for a while (detached
        /// window, occluded surface) would otherwise grow this without limit; content that moved
        /// through this many rects has scrolled far past any drag anchor worth carrying, so past the
        /// cap the buffer poisons itself, which reads as a cancelled carry exactly like an overflow.
        static let maxCarriedRects = 512

        private(set) var rects: [GhosttyRenderScrollRectOperation] = []
        private(set) var poisoned = false

        /// Appends one frame's contribution. Call once per distinct frame the view is given, in arrival
        /// order, before attempting to apply it.
        mutating func append(rects newRects: [GhosttyRenderScrollRectOperation], overflowed: Bool) {
            rects.append(contentsOf: newRects)
            if overflowed || rects.count > Self.maxCarriedRects { poisoned = true }
            // A poisoned buffer's rects can never be trusted again until `clear()`, so keeping them
            // only holds memory: the consumer reads `isCarryValid` first and cancels the carry.
            if poisoned { rects = [] }
        }

        /// Clears the buffer. Call only once the frame it was accumulated for has actually applied: a
        /// refused frame leaves the gap it was meant to cover unaccounted for, and clearing here would
        /// silently drop that gap from the next attempt.
        mutating func clear() {
            rects = []
            poisoned = false
        }

        /// Whether the accumulated rects can be trusted to fully describe how content moved since the
        /// last applied frame. Empty-and-unpoisoned (no movement at all since the last apply) is valid:
        /// it reports `scroll_carry_valid = true` with zero rects, which is the correct, complete answer
        /// for a gap with no scrolling in it.
        var isCarryValid: Bool { !poisoned }
    }

    /// Converts the mirror's own live local-drag selection (`ghostty_mirror_selection_info_s`, which
    /// reports viewport-relative, signed rows so an anchor scrolled above the mirror's visible grid still
    /// reads at its true row) into the daemon's absolute screen-space row (0 = oldest scrollback row),
    /// per `setSelection`'s contract. Clamped to 0: a virtual row so far above the offset that the
    /// absolute row would go negative has no absolute-space meaning, and 0, the oldest retained row, is
    /// the closest one that does.
    static func absoluteSelectionRow(virtualRow: Int32, scrollbarOffset: UInt32) -> UInt32 {
        let absolute = Int64(scrollbarOffset) + Int64(virtualRow)
        return UInt32(clamping: max(absolute, 0))
    }
}
