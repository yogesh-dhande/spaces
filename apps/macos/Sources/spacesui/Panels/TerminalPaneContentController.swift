import AppKit
import spacesterminalcore
import spacesterminalui

/// Terminal implementation of `PaneContentHosting`: wraps the session's Device API
/// state model (owned indirectly through the pane view controller's injected closures)
/// and the window-independent `TerminalSessionPaneViewController`. One instance per
/// open session, owned by `PanelCoordinator`; the pane view re-parents `contentView`
/// across layout rebuilds without recreating it.
@MainActor final class TerminalPaneContentController: PaneContentHosting {
    let descriptor: PaneContentDescriptor
    let workspaceID: String
    let sessionID: String
    /// Whether the session is an ad hoc shell (whose pane close stops the session) or a
    /// configured process/agent (which keeps running when its pane closes).
    let sessionKind: TerminalSessionKind
    private let pane: TerminalSessionPaneViewController

    var onTitleChanged: ((String) -> Void)?

    init(
        descriptor: PaneContentDescriptor, workspaceID: String, sessionID: String, sessionKind: TerminalSessionKind,
        pane: TerminalSessionPaneViewController
    ) {
        self.descriptor = descriptor
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.sessionKind = sessionKind
        self.pane = pane
        pane.onDisplayTitleChanged = { [weak self] title, _ in self?.onTitleChanged?(title) }
    }

    var contentView: NSView { pane.view }
    var displayTitle: String { pane.displayTitle }

    func activate(focus: Bool) { pane.showEmbedded(focus: focus) }

    func deactivate() { pane.hideEmbedded() }

    func close() { pane.closeEmbedded() }

    @discardableResult func makeContentFirstResponder() -> Bool {
        pane.focusEmbeddedTerminalInput()
        return true
    }

    func owns(responder: NSResponder) -> Bool { pane.ownsResponder(responder) }

    func handleKeyEvent(_ event: NSEvent) -> Bool { pane.handleKeyEvent(event) }

    func handleCommandKeyEquivalent(_ event: NSEvent) -> Bool { pane.handleCommandKeyEquivalent(event) }

    func debugStateDump() -> TerminalSessionWindowDebugState { pane.debugStateDump() }
}
