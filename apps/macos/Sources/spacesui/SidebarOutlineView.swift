import AppKit
import Carbon
import systembridge

final class SidebarOutlineView: NSOutlineView {
    /// Return `true` to indicate the row's click was fully handled; super.mouseDown is skipped.
    var onRowMouseDown: ((Int) -> Bool)?
    /// Context menu provider for the right-clicked row; nil falls back to the view's menu.
    var onRowMenu: ((Int) -> NSMenu?)?
    /// Draws one selected workspace region behind the workspace row and its visible targets.
    var selectedWorkspaceHighlight: (() -> (frame: NSRect, fill: NSColor, rail: NSColor)?)?

    /// Corner radius of the selection region's trailing (right) corners. The leading edge stays square
    /// so the accent rail reads as a flush bar.
    private static let selectionRadius: CGFloat = 5
    /// Width of the leading accent rail.
    private static let selectionRailWidth: CGFloat = 2

    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        guard let highlight = selectedWorkspaceHighlight?(), highlight.frame.intersects(clipRect) else { return }

        // Muted selection (design V2+V4): a neutral fill with a squared leading edge and rounded trailing
        // corners, and a teal rail on the leading edge as the sole accent — no full border.
        let frame = highlight.frame
        let fillPath = Self.leadingSquaredTrailingRoundedPath(frame, radius: Self.selectionRadius)
        highlight.fill.setFill()
        fillPath.fill()

        let railRect = NSRect(x: frame.minX, y: frame.minY, width: Self.selectionRailWidth, height: frame.height)
        highlight.rail.setFill()
        NSBezierPath(rect: railRect).fill()
    }

    /// A rect path with square leading (left) corners and rounded trailing (right) corners. Rounding both
    /// right corners symmetrically means the outline view's flipped coordinate space doesn't matter.
    private static func leadingSquaredTrailingRoundedPath(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let r = min(radius, min(rect.width, rect.height) / 2)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - r, y: rect.minY))
        path.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: 270, endAngle: 360)
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - r))
        path.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: 0, endAngle: 90)
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.close()
        return path
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
