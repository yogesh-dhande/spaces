import AppKit
import spacesterminalcore
import spacesterminalui

@MainActor protocol TerminalPaneContentHosting: PaneContentHosting {
    var workspaceID: String { get }
    var sessionID: String { get }
    func applyAppearance(_ appearance: ThemeAppearance)
    func applyTerminalTextSize(_ size: TerminalTextSize)
    func setAccessibilityRuntimeTargetName(_ name: String)
    func requestOwnershipIfNeeded()
    /// Whether this content already holds the session's owner attachment on a live surface (see
    /// `TerminalSessionPaneViewController.holdsOwnerAttachedSurface`). Lets a re-show of the pane the user
    /// is already in skip the open path's state fetch, attach, and ownership reclaim.
    var holdsOwnerAttachedSurface: Bool { get }
    func closeForSessionTermination()
    var canPerformFindActions: Bool { get }
    func find(_ sender: Any?)
    func findNext(_ sender: Any?)
    func findPrevious(_ sender: Any?)
    func useSelectionForFind(_ sender: Any?)
    func performShortcutForTesting(action: String, text: String?)
    func debugRefreshStateForTesting(skipOwnerAttach: Bool)
    func debugStateDump() -> TerminalSessionWindowDebugState
}

/// Terminal implementation of `PaneContentHosting`: wraps the session's Device API
/// state model (owned indirectly through the pane view controller's injected closures)
/// and the window-independent `TerminalSessionPaneViewController`. One instance per
/// open session, owned by `PanelCoordinator`; the pane view re-parents `contentView`
/// across layout rebuilds without recreating it.
@MainActor final class TerminalPaneContentController: TerminalPaneContentHosting {
    let descriptor: PaneContentDescriptor
    let workspaceID: String
    let sessionID: String
    private let pane: TerminalSessionPaneViewController
    /// Re-themes this session's live daemon rendering to `appearance` (see
    /// `AppKitController.applyAppearanceToLiveSession`). Dedupe and pending-attach state live in the
    /// session's shared appearance store, captured by the closure, so this controller holds no copy.
    private let setAppearanceAction: (ThemeAppearance) -> Void
    /// Routes terminal link clicks for this pane (fetches remote artifacts, shows the loopback notice).
    /// Owned here so its in-flight fetch is cancelled when the pane closes. Nil for panes built without
    /// a coordinator (e.g. tests).
    private let linkOpenCoordinator: TerminalLinkOpenCoordinator?

    var onTitleChanged: ((String) -> Void)?

    init(
        descriptor: PaneContentDescriptor, workspaceID: String, sessionID: String, pane: TerminalSessionPaneViewController,
        setAppearanceAction: @escaping (ThemeAppearance) -> Void, terminalTextZoomAction: @escaping @MainActor (TerminalTextZoomCommand) -> Void,
        linkOpenCoordinator: TerminalLinkOpenCoordinator? = nil
    ) {
        self.descriptor = descriptor
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.pane = pane
        self.setAppearanceAction = setAppearanceAction
        self.linkOpenCoordinator = linkOpenCoordinator
        pane.onDisplayTitleChanged = { [weak self] title, _ in self?.onTitleChanged?(title) }
        pane.terminalTextZoomAction = terminalTextZoomAction
    }

    /// Re-themes this session's live daemon rendering to the app's current light/dark appearance. Called by
    /// `PanelCoordinator.broadcastAppearance` for every open pane when the app appearance changes.
    func applyAppearance(_ appearance: ThemeAppearance) { setAppearanceAction(appearance) }

    /// Renders this pane's terminal content at the app-wide terminal text size. Called by
    /// `PanelCoordinator.broadcastTerminalTextSize` for every open pane when the size changes, and once
    /// when the pane is built so it opens at the size the profile already holds.
    func applyTerminalTextSize(_ size: TerminalTextSize) { pane.applyTerminalTextSize(size) }

    var contentView: NSView { pane.view }
    var displayTitle: String { pane.displayTitle }

    func activate(focus: Bool) { pane.showEmbedded(focus: focus) }

    /// Mirrors the pane's resolved tab title (the runtime target's name) onto its content
    /// view's accessibility label so UI automation can match the front window's selected-tab
    /// session by name. Pushed by `PanelCoordinator` on every render.
    func setAccessibilityRuntimeTargetName(_ name: String) { pane.setAccessibilityRuntimeTargetName(name) }

    /// Reclaims owner attachment for the session, preempting a different active owner
    /// (e.g. a mobile client that took the session over) when the runtime is interactive.
    /// The `openTerminalSessionWindow` (owner) IPC calls this after opening the pane;
    /// without it an owner-mode `terminal show` would only attach as a viewer.
    func requestOwnershipIfNeeded() { pane.requestOwnershipIfNeeded() }

    var holdsOwnerAttachedSurface: Bool { pane.holdsOwnerAttachedSurface }

    func deactivate() { pane.hideEmbedded() }

    func close() {
        linkOpenCoordinator?.cancelActiveOpen()
        pane.closeEmbedded()
    }

    /// Tears the pane down for a daemon-driven session termination: the session is
    /// already stopping, so the client detach and ad hoc stop are skipped.
    func closeForSessionTermination() {
        linkOpenCoordinator?.cancelActiveOpen()
        pane.closeEmbedded(sessionIsTerminating: true)
    }

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

    // MARK: - E2E/testing passthroughs (driven by the terminal IPC handlers)

    func performShortcutForTesting(action: String, text: String?) { pane.performShortcutForTesting(action: action, text: text) }

    func debugRefreshStateForTesting(skipOwnerAttach: Bool) { pane.debugRefreshStateForTesting(skipOwnerAttach: skipOwnerAttach) }

    func debugStateDump() -> TerminalSessionWindowDebugState { pane.debugStateDump() }
}
