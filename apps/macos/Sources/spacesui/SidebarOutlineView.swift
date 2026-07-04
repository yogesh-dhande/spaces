import AppKit
import Carbon

final class SidebarOutlineView: NSOutlineView {
    /// Return `true` to indicate the row's click was fully handled; super.mouseDown is skipped.
    var onRowMouseDown: ((Int) -> Bool)?
    /// Return `true` to indicate the arrow key navigation was fully handled.
    var onArrowNavigation: ((Int) -> Bool)?
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
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags.isEmpty {
            switch event.keyCode {
            case UInt16(kVK_UpArrow): if onArrowNavigation?(-1) == true { return }
            case UInt16(kVK_DownArrow): if onArrowNavigation?(1) == true { return }
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func moveUp(_ sender: Any?) {
        if onArrowNavigation?(-1) == true { return }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if onArrowNavigation?(1) == true { return }
        super.moveDown(sender)
    }

    // Hide the built-in disclosure triangle while keeping the expand/collapse cell alive
    // so that collapseItem/expandItem continue to work. The right-side chevron in each row
    // cell serves as the visible indicator instead.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
}
