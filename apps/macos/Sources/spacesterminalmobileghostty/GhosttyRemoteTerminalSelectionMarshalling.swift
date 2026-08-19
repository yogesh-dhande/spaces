import Foundation
import spacesterminalcore

/// Pure, MainActor-free helper that maps the shared-selection/scrollbar wire model
/// (`GhosttyTerminalSelectionRange`) onto the GhosttyKit C frame fields the iOS mirror surface reads
/// (`ghostty_terminal_snapshot_s`'s `selection_flags`/`selection_start_*`/`selection_end_*`/`scrollbar_*`).
///
/// This duplicates `GhosttyMirrorSelectionMarshalling` from the macOS-only `spacesterminalghostty` target
/// rather than importing it: `spacesterminalmobileghostty` depends only on `spacesterminalcore` and
/// `GhosttyKit`, not on the AppKit mirror target, so the mapping is kept here instead as its own small,
/// independently testable unit. iOS never drags a local selection, so unlike the macOS counterpart this
/// has no scroll-rect carry buffer or absolute-row conversion: the mirrored selection is always the
/// daemon's shared selection, applied read-only.
enum GhosttyRemoteTerminalSelectionMarshalling {
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
    static func cSnapshotSelectionFields(selection: GhosttyTerminalSelectionRange?, scrollbarTotal: UInt32, scrollbarOffset: UInt32)
        -> CSnapshotSelectionFields
    {
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
}
