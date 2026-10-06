import AppKit

extension NSView {
    /// The deepest view of this subtree under the event's window location, or nil when the point misses it
    /// or the view has no superview.
    ///
    /// `hitTest(_:)` takes its point in the superview's coordinate system. A row below its container's top
    /// that passes its own coordinates lands outside its own frame, finds nothing, and so never sees the
    /// controls inside it: a click on them also fired the row's action.
    func deepestView(at event: NSEvent) -> NSView? {
        guard let superview else { return nil }
        return hitTest(superview.convert(event.locationInWindow, from: nil))
    }
}
