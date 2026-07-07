import AppKit
import Carbon

final class SidebarOutlineView: NSOutlineView {
    /// Return `true` to indicate the row's click was fully handled; super.mouseDown is skipped.
    var onRowMouseDown: ((Int) -> Bool)?
    /// Context menu provider for the right-clicked row; nil falls back to the view's menu.
    var onRowMenu: ((Int) -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        if clicked >= 0, onRowMouseDown?(clicked) == true { return }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        if clicked >= 0, let menu = onRowMenu?(clicked) { return menu }
        return super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        // Sidebar selection moves only via the configurable leader+up/down chords (handled by
        // the app-wide shortcut monitor), so plain arrows have a single, predictable path. Swallow
        // unmodified up/down here to suppress the outline view's native row-by-row selection, which
        // would otherwise step onto device/project header rows that aren't selectable destinations.
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags.isEmpty, event.keyCode == UInt16(kVK_UpArrow) || event.keyCode == UInt16(kVK_DownArrow) { return }
        super.keyDown(with: event)
    }

    // Hide the built-in disclosure triangle while keeping the expand/collapse cell alive
    // so that collapseItem/expandItem continue to work. The right-side chevron in each row
    // cell serves as the visible indicator instead.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
}
