import AppKit

/// The generic content a pane hosts. Terminal sessions are the only implementation
/// today; future kinds (code editor, file preview) adopt the same protocol and add a
/// `PaneContentDescriptor` case, leaving the panel/tab machinery untouched.
///
/// Lifecycle: a content controller is created when its pane first materializes and
/// lives until the pane is explicitly closed. `activate`/`deactivate` bracket tab
/// visibility (a hidden tab's content stays alive but may release expensive resources
/// like renderer surfaces); `close` is the one-way teardown when the pane is removed.
@MainActor protocol PaneContentHosting: AnyObject {
    var descriptor: PaneContentDescriptor { get }
    /// The view installed into the pane's content container, pinned to its edges.
    var contentView: NSView { get }
    var displayTitle: String { get }
    /// Fired when the content's title changes (e.g. terminal set_title); the pane header
    /// and tab label observe it.
    var onTitleChanged: ((String) -> Void)? { get set }
    /// Content became visible (its tab selected / window shown). `focus` moves keyboard
    /// focus into the content.
    func activate(focus: Bool)
    /// Content is hidden (tab switched away or window closed without removing the pane).
    func deactivate()
    /// Pane removed: detach clients and release everything. The controller is discarded
    /// afterwards.
    func close()
    /// Moves keyboard focus into the content. Returns false when not currently possible.
    @discardableResult func makeContentFirstResponder() -> Bool
    /// Whether the given responder lives inside this content (drives focused-pane
    /// tracking from window first-responder changes).
    func owns(responder: NSResponder) -> Bool
    /// Window-level key routing for the focused pane (Ghostty translation for
    /// terminals). Returns true when the event was consumed.
    func handleKeyEvent(_ event: NSEvent) -> Bool
    func handleCommandKeyEquivalent(_ event: NSEvent) -> Bool
}
