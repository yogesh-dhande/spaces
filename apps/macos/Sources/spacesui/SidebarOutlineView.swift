import AppKit
import Carbon
import systembridge

final class SidebarOutlineView: NSOutlineView {
    /// Return `true` to indicate the row's click was fully handled; super.mouseDown is skipped.
    var onRowMouseDown: ((Int) -> Bool)?
    /// Context menu provider for the right-clicked row; nil falls back to the view's menu.
    var onRowMenu: ((Int) -> NSMenu?)?
    /// Draws one selected workspace region behind the workspace row and its visible targets.
    var selectedWorkspaceHighlight: (() -> (frame: NSRect, fill: NSColor, border: NSColor)?)?

    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        guard let highlight = selectedWorkspaceHighlight?(), highlight.frame.intersects(clipRect) else { return }

        let fillPath = NSBezierPath(
            roundedRect: highlight.frame, xRadius: UIRadius.regular, yRadius: UIRadius.regular)
        highlight.fill.setFill()
        fillPath.fill()

        let strokeFrame = highlight.frame.insetBy(dx: 0.5, dy: 0.5)
        let strokePath = NSBezierPath(roundedRect: strokeFrame, xRadius: UIRadius.regular, yRadius: UIRadius.regular)
        strokePath.lineWidth = 1
        highlight.border.setStroke()
        strokePath.stroke()
    }

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
