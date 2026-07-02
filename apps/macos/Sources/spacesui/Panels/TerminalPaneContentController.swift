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
    private let pane: TerminalSessionPaneViewController

    var onTitleChanged: ((String) -> Void)?

    init(descriptor: PaneContentDescriptor, workspaceID: String, sessionID: String, pane: TerminalSessionPaneViewController) {
        self.descriptor = descriptor
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.pane = pane
        pane.onDisplayTitleChanged = { [weak self] title, _ in self?.onTitleChanged?(title) }
    }

    var contentView: NSView { pane.view }
    var displayTitle: String { pane.displayTitle }

    func activate(focus: Bool) { pane.showEmbedded(focus: focus) }

    func deactivate() { pane.hideEmbedded() }

    func close() { pane.closeEmbedded() }

    /// Tears the pane down for a daemon-driven session termination: the session is
    /// already stopping, so the client detach and ad hoc stop are skipped.
    func closeForSessionTermination() { pane.closeEmbedded(sessionIsTerminating: true) }

    @discardableResult func makeContentFirstResponder() -> Bool {
        pane.focusEmbeddedTerminalInput()
        return true
    }

    func owns(responder: NSResponder) -> Bool { pane.ownsResponder(responder) }

    func handleKeyEvent(_ event: NSEvent) -> Bool { pane.handleKeyEvent(event) }

    func handleCommandKeyEquivalent(_ event: NSEvent) -> Bool { pane.handleCommandKeyEquivalent(event) }

    // MARK: - Edit-menu actions (dispatched by the main menu to the focused pane)

    /// Whether the pane can currently run the find family of actions (one shared
    /// validation case in the pane view controller covers all four).
    var canPerformFindActions: Bool {
        let probe = NSMenuItem()
        probe.action = #selector(TerminalSessionPaneViewController.find(_:))
        return pane.validateUserInterfaceItem(probe)
    }

    func find(_ sender: Any?) { pane.find(sender) }

    func findNext(_ sender: Any?) { pane.findNext(sender) }

    func findPrevious(_ sender: Any?) { pane.findPrevious(sender) }

    func useSelectionForFind(_ sender: Any?) { pane.useSelectionForFind(sender) }

    func setRuntimeControls(_ controls: TerminalSessionRuntimeControls?) { pane.setRuntimeControls(controls) }

    // MARK: - E2E/testing passthroughs (driven by the terminal IPC handlers)

    func performShortcutForTesting(action: String, text: String?) { pane.performShortcutForTesting(action: action, text: text) }

    func debugRefreshStateForTesting(skipOwnerAttach: Bool) { pane.debugRefreshStateForTesting(skipOwnerAttach: skipOwnerAttach) }

    func debugStateDump() -> TerminalSessionWindowDebugState { pane.debugStateDump() }
}
