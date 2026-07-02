import AppKit
import spacesdevicecore

/// Owns every panel's layout, view, and pane-content lifecycle. One instance on
/// `AppKitController` (the standard unowned-host sub-controller). Invariant: a terminal
/// session has at most one pane across all panels — opening an already-open session
/// focuses its pane wherever it lives instead of creating another.
@MainActor final class PanelCoordinator {
    unowned let host: AppKitController

    init(host: AppKitController) {
        self.host = host
    }

    struct PanePlacement: Equatable {
        let scope: PanelScope
        let tabID: String
        let paneID: String
    }

    private struct PanelState {
        var layout = PanelLayout()
        var view: WorkspacePanelView?
    }

    private var panels: [PanelScope: PanelState] = [:]
    /// Live content controllers keyed by terminal session id.
    private var contentControllers: [String: TerminalPaneContentController] = [:]
    /// Window shells for materialized global panels, keyed by panel window id.
    private var panelWindows: [String: PanelWindowController] = [:]
    /// Persistence hook, wired to the client database; called after every layout change.
    var onLayoutChanged: ((PanelScope, PanelLayout) -> Void)?

    // MARK: - Panel access

    func layout(for scope: PanelScope) -> PanelLayout { panels[scope]?.layout ?? PanelLayout() }

    /// The panel's view, materialized on first request and retained (detached while
    /// its workspace is unselected) so pane content survives workspace switching.
    func panelView(for scope: PanelScope) -> WorkspacePanelView {
        if let view = panels[scope]?.view { return view }
        let view = WorkspacePanelView(scope: scope)
        view.onSelectTab = { [weak self] tabID in self?.selectTab(scope: scope, tabID: tabID) }
        view.onCloseTab = { [weak self] tabID in self?.closeTab(scope: scope, tabID: tabID) }
        view.onRenameTab = { [weak self] tabID, title in self?.renameTab(scope: scope, tabID: tabID, title: title) }
        view.onNewTab = { [weak self] in self?.host.openNewTerminalTab(scope: scope) }
        view.onSplitPane = { [weak self] paneID, direction in self?.beginSplit(scope: scope, paneID: paneID, direction: direction) }
        view.onFocusPane = { [weak self] paneID in self?.focusPane(scope: scope, paneID: paneID, moveKeyboardFocus: true) }
        view.onSplitWeightsChanged = { [weak self] splitID, weights in self?.updateSplitWeights(scope: scope, splitID: splitID, weights: weights) }
        view.paneContentProvider = { [weak self] pane in
            guard let sessionID = pane.content.terminalSessionID else { return nil }
            return self?.contentControllers[sessionID]
        }
        panels[scope, default: PanelState()].view = view
        render(scope: scope)
        return view
    }

    // MARK: - Registry

    /// Where a session's pane lives, if it is open anywhere.
    func placement(forSessionID sessionID: String) -> PanePlacement? {
        for (scope, state) in panels {
            for tab in state.layout.tabs {
                for pane in PanelLayoutEngine.panes(in: tab) where pane.content.terminalSessionID == sessionID {
                    return PanePlacement(scope: scope, tabID: tab.id, paneID: pane.id)
                }
            }
        }
        return nil
    }

    /// Ordered open session ids for a workspace across all panels: its workspace panel
    /// first (tab order), then panes of that workspace hosted in global panel windows.
    /// This is the "open targets" source for window cycling.
    func openTerminalSessionIDs(workspaceID: String) -> [String] {
        var ordered: [String] = []
        for (scope, state) in panels.sorted(by: { scopeSortKey($0.key) < scopeSortKey($1.key) }) {
            switch scope {
            case .workspace(_, let scopeWorkspaceID):
                guard scopeWorkspaceID == workspaceID else { continue }
                ordered.append(contentsOf: PanelLayoutEngine.orderedTerminalSessionIDs(in: state.layout))
            case .globalWindow:
                for sessionID in PanelLayoutEngine.orderedTerminalSessionIDs(in: state.layout)
                where contentControllers[sessionID]?.workspaceID == workspaceID {
                    ordered.append(sessionID)
                }
            }
        }
        return ordered
    }

    private func scopeSortKey(_ scope: PanelScope) -> String {
        switch scope {
        case .workspace(let deviceID, let workspaceID): return "0:\(deviceID):\(workspaceID)"
        case .globalWindow(let panelWindowID): return "1:\(panelWindowID)"
        }
    }

    /// The live content controller for a session, if its pane is open anywhere.
    func content(forSessionID sessionID: String) -> TerminalPaneContentController? { contentControllers[sessionID] }

    /// The content controller owning `responder` (keyboard-routing and focus lookups).
    func contentOwning(responder: NSResponder?) -> TerminalPaneContentController? {
        guard let responder else { return nil }
        for controller in contentControllers.values where controller.owns(responder: responder) { return controller }
        return nil
    }

    /// The session whose pane currently holds keyboard focus in the key window, if any.
    func focusedSessionID() -> String? { contentOwning(responder: NSApp.keyWindow?.firstResponder)?.sessionID }

    /// Syncs the layout's focused pane to the content that actually has keyboard focus
    /// (clicks inside terminal content bypass the pane chrome's mouse handling, so the
    /// shortcut monitor calls this as typing reveals where focus really is).
    func noteContentFocused(_ content: TerminalPaneContentController) {
        guard let placement = placement(forSessionID: content.sessionID) else { return }
        guard layout(for: placement.scope).focusedPaneID != placement.paneID else { return }
        focusPane(scope: placement.scope, paneID: placement.paneID, moveKeyboardFocus: false)
    }

    // MARK: - Open / focus

    /// The unified open-or-focus behavior behind sidebar clicks, the command palette,
    /// numbered shortcuts, and cycling: focus the session's existing pane wherever it
    /// lives, else open it as a new tab in its workspace's panel.
    @discardableResult func openOrFocusTerminalPane(_ request: AppKitController.DeviceTerminalOpenRequest) -> Bool {
        if let placement = placement(forSessionID: request.sessionID) {
            focus(placement: placement)
            return true
        }
        return openSessionInNewTab(request)
    }

    /// Opens the session as a new tab — in its workspace's panel by default (the
    /// cmd+opt+t landing path for a freshly created session), or in an explicit scope
    /// (a global panel window's "+" button).
    @discardableResult func openSessionInNewTab(_ request: AppKitController.DeviceTerminalOpenRequest, in scope: PanelScope? = nil) -> Bool {
        let scope = scope ?? workspaceScope(forWorkspaceID: request.workspaceID)
        guard let content = ensureContentController(request: request) else { return false }
        let pane = Pane(id: UUID().uuidString, content: content.descriptor)
        mutateLayout(scope: scope) { PanelLayoutEngine.appendTab(tabID: UUID().uuidString, pane: pane, to: $0) }
        host.showPanelScope(scope)
        activateFocusedPane(scope: scope)
        return true
    }

    /// Adopts a persisted layout for a workspace panel the first time it is shown,
    /// materializing content controllers for its still-live sessions.
    func restoreLayoutIfNeeded(scope: PanelScope) {
        guard panels[scope] == nil, case .workspace(let deviceID, let workspaceID) = scope,
            let layout = host.restoredWorkspacePanelLayout(deviceID: deviceID, workspaceID: workspaceID), !layout.isEmpty
        else { return }
        panels[scope] = PanelState(layout: layout, view: nil)
        for pane in PanelLayoutEngine.allPanes(in: layout) {
            guard let sessionID = pane.content.terminalSessionID, contentControllers[sessionID] == nil,
                let request = host.paneOpenRequest(workspaceID: workspaceID, sessionID: sessionID)
            else { continue }
            _ = ensureContentController(request: request)
        }
    }

    // MARK: - Global panel windows

    /// The panel window id owning `window`, when it is one of our global panel shells.
    func panelWindowID(forWindow window: NSWindow?) -> String? {
        guard let window else { return nil }
        return panelWindows.first { $0.value.window === window }?.key
    }

    /// The shell window's frame for persistence, once the window is materialized.
    func panelWindowFrame(panelWindowID: String) -> (x: Double, y: Double, width: Double, height: Double)? {
        guard let frame = panelWindows[panelWindowID]?.window.frame else { return nil }
        return (x: Double(frame.origin.x), y: Double(frame.origin.y), width: Double(frame.size.width), height: Double(frame.size.height))
    }

    /// Moves a session's pane into a fresh global panel window (the sidebar's
    /// "Open in New Window"): the source pane is removed — never copied — so the
    /// one-pane-per-session invariant holds. A session not open anywhere simply opens
    /// in the new window. A session already alone in a global window keeps that window
    /// and is brought front instead (a move would only rebuild an identical window).
    func moveSessionToNewPanelWindow(_ request: AppKitController.DeviceTerminalOpenRequest) {
        if let existing = placement(forSessionID: request.sessionID) {
            if case .globalWindow = existing.scope, isLonePane(scope: existing.scope) {
                focus(placement: existing)
                return
            }
            mutateLayout(scope: existing.scope) { PanelLayoutEngine.removePane(paneID: existing.paneID, from: $0) }
        }
        guard let content = ensureContentController(request: request) else { return }
        let scope = PanelScope.globalWindow(panelWindowID: UUID().uuidString)
        let pane = Pane(id: UUID().uuidString, content: content.descriptor)
        mutateLayout(scope: scope) { PanelLayoutEngine.appendTab(tabID: UUID().uuidString, pane: pane, to: $0) }
        host.showPanelScope(scope)
        activateFocusedPane(scope: scope)
    }

    private func isLonePane(scope: PanelScope) -> Bool {
        let layout = layout(for: scope)
        return layout.tabs.count == 1 && PanelLayoutEngine.allPanes(in: layout).count == 1
    }

    /// Materializes (if needed) and fronts a global panel's window shell.
    func showPanelWindow(panelWindowID: String, frame: NSRect? = nil, makeKey: Bool) {
        let controller = panelWindowController(for: panelWindowID, frame: frame)
        guard !AppKitController.isRunningUnderXCTest else { return }
        if makeKey { controller.window.makeKeyAndOrderFront(nil) } else { controller.window.orderFront(nil) }
    }

    private func panelWindowController(for panelWindowID: String, frame: NSRect?) -> PanelWindowController {
        if let existing = panelWindows[panelWindowID] { return existing }
        let scope = PanelScope.globalWindow(panelWindowID: panelWindowID)
        let controller = PanelWindowController(panelWindowID: panelWindowID, panelView: panelView(for: scope), frame: frame)
        controller.window.backgroundColor = host.sidebarPanelBackgroundColor()
        controller.onUserClose = { [weak self] in self?.closePanelWindow(panelWindowID: panelWindowID) }
        controller.onFrameChanged = { [weak self] in
            guard let self else { return }
            self.onLayoutChanged?(scope, self.layout(for: scope))
        }
        panelWindows[panelWindowID] = controller
        syncPanelWindowTitle(scope: scope)
        // Re-persist now that a frame exists (a fresh window's first layout write
        // happens before the shell is created, so it carried no frame).
        onLayoutChanged?(scope, layout(for: scope))
        return controller
    }

    /// User close of a panel window (red button / performClose): closes every tab's
    /// content, which empties the layout; the empty-layout dismissal funnel then
    /// removes the shell and the persisted row.
    func closePanelWindow(panelWindowID: String) {
        let scope = PanelScope.globalWindow(panelWindowID: panelWindowID)
        for tab in layout(for: scope).tabs { closeTab(scope: scope, tabID: tab.id) }
    }

    /// The panel-window ⌘W behavior: close the selected tab; closing the last tab
    /// closes the window through the empty-layout dismissal funnel.
    func closeSelectedTab(panelWindowID: String) {
        let scope = PanelScope.globalWindow(panelWindowID: panelWindowID)
        guard let tabID = layout(for: scope).selectedTabID else { return }
        closeTab(scope: scope, tabID: tabID)
    }

    /// Reopens a persisted global panel window at startup: adopts the (already pruned)
    /// layout, materializes content controllers for its sessions, and shows the shell
    /// at its saved frame without stealing focus.
    func restorePanelWindow(panelWindowID: String, layout: PanelLayout, frame: NSRect?) {
        let scope = PanelScope.globalWindow(panelWindowID: panelWindowID)
        guard panels[scope] == nil else { return }
        panels[scope] = PanelState(layout: layout, view: nil)
        for pane in PanelLayoutEngine.allPanes(in: layout) {
            guard let sessionID = pane.content.terminalSessionID, contentControllers[sessionID] == nil,
                let workspaceID = host.clientWorkspaceID(forTerminalSession: sessionID),
                let request = host.paneOpenRequest(workspaceID: workspaceID, sessionID: sessionID)
            else { continue }
            _ = ensureContentController(request: request)
        }
        showPanelWindow(panelWindowID: panelWindowID, frame: frame, makeKey: false)
        restoreSelection(scope: scope)
    }

    /// Single teardown funnel for a global panel whose layout emptied (last tab
    /// closed, last pane moved away, or user window close): drops the panel state and
    /// closes the shell. The persisted row was already deleted by the empty-layout
    /// persist that triggered this.
    private func dismissPanelWindowShell(panelWindowID: String) {
        let scope = PanelScope.globalWindow(panelWindowID: panelWindowID)
        panels[scope] = nil
        guard let controller = panelWindows.removeValue(forKey: panelWindowID) else { return }
        controller.onUserClose = nil
        controller.onFrameChanged = nil
        controller.window.delegate = nil
        controller.window.close()
    }

    private func syncPanelWindowTitle(scope: PanelScope) {
        guard case .globalWindow(let panelWindowID) = scope, let controller = panelWindows[panelWindowID] else { return }
        let layout = layout(for: scope)
        controller.window.title = layout.selectedTabID.map { tabTitle(forTabID: $0, in: layout) } ?? "Terminals"
    }

    private func focus(placement: PanePlacement) {
        mutateLayout(scope: placement.scope) { PanelLayoutEngine.focusPane(paneID: placement.paneID, in: $0) }
        host.showPanelScope(placement.scope)
        activateFocusedPane(scope: placement.scope)
    }

    /// Focuses a session's existing pane, if it has one (command-palette return focus).
    @discardableResult func focusPane(forSessionID sessionID: String) -> Bool {
        guard let placement = placement(forSessionID: sessionID) else { return false }
        focus(placement: placement)
        return true
    }

    func focusPane(scope: PanelScope, paneID: String, moveKeyboardFocus: Bool) {
        mutateLayout(scope: scope) { PanelLayoutEngine.focusPane(paneID: paneID, in: $0) }
        if moveKeyboardFocus { activateFocusedPane(scope: scope) }
    }

    /// Restores a workspace panel's remembered focus when the sidebar selection lands
    /// on it (arrow-key workspace switching), without stealing keyboard focus from the
    /// sidebar.
    func restoreSelection(scope: PanelScope) {
        for tab in layout(for: scope).tabs {
            for pane in PanelLayoutEngine.panes(in: tab) { activateContentIfVisible(scope: scope, pane: pane) }
        }
        render(scope: scope)
    }

    private func activateFocusedPane(scope: PanelScope) {
        let layout = layout(for: scope)
        guard let focusedPaneID = layout.focusedPaneID, let pane = PanelLayoutEngine.pane(withID: focusedPaneID, in: layout),
            let sessionID = pane.content.terminalSessionID, let content = contentControllers[sessionID]
        else { return }
        content.activate(focus: true)
    }

    private func activateContentIfVisible(scope: PanelScope, pane: Pane) {
        guard let sessionID = pane.content.terminalSessionID, let content = contentControllers[sessionID] else { return }
        let layout = layout(for: scope)
        let isInSelectedTab = layout.tabs.first { $0.id == layout.selectedTabID }.map {
            PanelLayoutEngine.panes(in: $0).contains { $0.id == pane.id }
        } ?? false
        if isInSelectedTab { content.activate(focus: false) } else { content.deactivate() }
    }

    // MARK: - Tabs and panes

    func selectTab(scope: PanelScope, tabID: String) {
        mutateLayout(scope: scope) { PanelLayoutEngine.selectTab(tabID: tabID, in: $0) }
        activateFocusedPane(scope: scope)
    }

    /// Sets a tab's user-chosen name (persisted with the layout); an empty name
    /// returns the tab to its derived title.
    func renameTab(scope: PanelScope, tabID: String, title: String?) {
        mutateLayout(scope: scope) { PanelLayoutEngine.renameTab(tabID: tabID, title: title, in: $0) }
    }

    func closeTab(scope: PanelScope, tabID: String) {
        let closing = layout(for: scope).tabs.first { $0.id == tabID }
        guard let closing else { return }
        for pane in PanelLayoutEngine.panes(in: closing) { closeContent(for: pane) }
        mutateLayout(scope: scope) { layout in
            var layout = layout
            layout.tabs.removeAll { $0.id == tabID }
            return PanelLayoutEngine.normalized(layout)
        }
        activateFocusedPane(scope: scope)
    }

    func closePane(scope: PanelScope, paneID: String) {
        if let pane = PanelLayoutEngine.pane(withID: paneID, in: layout(for: scope)) { closeContent(for: pane) }
        mutateLayout(scope: scope) { PanelLayoutEngine.removePane(paneID: paneID, from: $0) }
        activateFocusedPane(scope: scope)
    }

    /// Closes a session's pane wherever it lives. `sessionIsTerminating` marks a
    /// daemon-driven close (the session is already stopping), so the client detach —
    /// and with it the attachment-driven unattached ad hoc cleanup — is skipped.
    func closePane(forSessionID sessionID: String, sessionIsTerminating: Bool = false) {
        guard let placement = placement(forSessionID: sessionID) else { return }
        if sessionIsTerminating, let content = contentControllers.removeValue(forKey: sessionID) { content.closeForSessionTermination() }
        closePane(scope: placement.scope, paneID: placement.paneID)
    }

    /// Detaches every open pane's terminal client at app termination without stopping
    /// sessions (daemon-owned sessions keep running across quit; panes are rebuilt on
    /// relaunch from the persisted layout).
    func closeAllContentForTermination() {
        for content in contentControllers.values { content.close() }
    }

    private func closeContent(for pane: Pane) {
        guard let sessionID = pane.content.terminalSessionID, let content = contentControllers.removeValue(forKey: sessionID) else { return }
        // Closing detaches the pane's client; the attachment-state observer then runs
        // the unattached ad hoc cleanup against the authoritative snapshot, so an ad
        // hoc shell stops only when no other client is still attached.
        content.close()
    }

    private func beginSplit(scope: PanelScope, paneID: String, direction: PaneSplitDirection) {
        // "New terminal session" targets the split pane's own workspace (which is the
        // panel's workspace for a workspace scope, and the source pane's for global).
        let sourceWorkspaceID: String?
        if let pane = PanelLayoutEngine.pane(withID: paneID, in: layout(for: scope)), let sessionID = pane.content.terminalSessionID {
            sourceWorkspaceID = contentControllers[sessionID]?.workspaceID
        } else {
            sourceWorkspaceID = nil
        }
        let newTerminalWorkspaceID: String
        switch scope {
        case .workspace(_, let workspaceID): newTerminalWorkspaceID = sourceWorkspaceID ?? workspaceID
        case .globalWindow:
            guard let sourceWorkspaceID else { return }
            newTerminalWorkspaceID = sourceWorkspaceID
        }
        host.presentPaneSplitSessionPicker(scope: scope, newTerminalWorkspaceID: newTerminalWorkspaceID) { [weak self] request in
            guard let self, let request else { return }
            self.fillSplit(scope: scope, paneID: paneID, direction: direction, request: request)
        }
    }

    private func fillSplit(scope: PanelScope, paneID: String, direction: PaneSplitDirection, request: AppKitController.DeviceTerminalOpenRequest) {
        // A session already open elsewhere moves into the new split rather than
        // duplicating (one pane per session).
        if let existing = placement(forSessionID: request.sessionID) {
            mutateLayout(scope: existing.scope) { PanelLayoutEngine.removePane(paneID: existing.paneID, from: $0) }
        }
        guard let content = ensureContentController(request: request) else { return }
        let pane = Pane(id: UUID().uuidString, content: content.descriptor)
        mutateLayout(scope: scope) { layout in
            PanelLayoutEngine.splitPane(paneID: paneID, direction: direction, newPane: pane, newSplitID: UUID().uuidString, in: layout) ?? layout
        }
        activateFocusedPane(scope: scope)
    }

    private func updateSplitWeights(scope: PanelScope, splitID: String, weights: [Double]) {
        mutateLayout(scope: scope, rerender: false) { layout in
            var layout = layout
            layout.tabs = layout.tabs.map { tab in
                var tab = tab
                tab.root = Self.applyingWeights(weights, toSplitID: splitID, in: tab.root)
                return tab
            }
            return layout
        }
    }

    private static func applyingWeights(_ weights: [Double], toSplitID splitID: String, in node: PaneNode) -> PaneNode {
        switch node {
        case .leaf: return node
        case .split(var split):
            if split.id == splitID, split.children.count == weights.count { split.weights = weights }
            split.children = split.children.map { applyingWeights(weights, toSplitID: splitID, in: $0) }
            return .split(split)
        }
    }

    // MARK: - Content lifecycle

    private func ensureContentController(request: AppKitController.DeviceTerminalOpenRequest) -> TerminalPaneContentController? {
        if let existing = contentControllers[request.sessionID] { return existing }
        guard let content = host.makeTerminalPaneContent(request: request) else { return nil }
        content.onTitleChanged = { [weak self, weak content] title in
            guard let self, let content, let sessionID = content.descriptor.terminalSessionID,
                let placement = self.placement(forSessionID: sessionID)
            else { return }
            self.refreshTabTitles(forSessionID: sessionID)
        }
        contentControllers[request.sessionID] = content
        return content
    }

    private func refreshTabTitles(forSessionID sessionID: String?) {
        guard let sessionID, let placement = placement(forSessionID: sessionID), let view = panels[placement.scope]?.view else { return }
        view.updateTabTitle(tabTitle(forTabID: placement.tabID, in: layout(for: placement.scope)), forTabID: placement.tabID)
        syncPanelWindowTitle(scope: placement.scope)
        syncFocusedPaneFooter(scope: placement.scope)
    }

    /// The selected workspace footer shows the focused pane's identity; re-sync it
    /// whenever a workspace panel's layout or titles change.
    private func syncFocusedPaneFooter(scope: PanelScope) {
        guard case .workspace(_, let workspaceID) = scope else { return }
        host.refreshWorkspaceFooterFocusedPane(workspaceID: workspaceID)
    }

    /// The focused pane's identity for a workspace panel (footer display).
    func focusedPaneInfo(deviceID: String, workspaceID: String) -> (paneID: String, title: String)? {
        let layout = layout(for: .workspace(deviceID: deviceID, workspaceID: workspaceID))
        guard let paneID = layout.focusedPaneID, let pane = PanelLayoutEngine.pane(withID: paneID, in: layout),
            let sessionID = pane.content.terminalSessionID
        else { return nil }
        return (paneID, contentControllers[sessionID]?.displayTitle ?? "Terminal")
    }

    /// Closes the focused pane of a workspace's panel (the footer's close control).
    func closeFocusedPane(deviceID: String, workspaceID: String) {
        let scope = PanelScope.workspace(deviceID: deviceID, workspaceID: workspaceID)
        guard let paneID = layout(for: scope).focusedPaneID else { return }
        closePane(scope: scope, paneID: paneID)
    }

    /// A tab is titled after its user-chosen name when set, else its first pane's
    /// content.
    private func tabTitle(forTabID tabID: String, in layout: PanelLayout) -> String {
        guard let tab = layout.tabs.first(where: { $0.id == tabID }) else { return "Terminal" }
        if let custom = tab.title { return custom }
        guard let first = PanelLayoutEngine.panes(in: tab).first, let sessionID = first.content.terminalSessionID else { return "Terminal" }
        return contentControllers[sessionID]?.displayTitle ?? "Terminal"
    }

    // MARK: - Rendering / persistence

    private func workspaceScope(forWorkspaceID workspaceID: String) -> PanelScope {
        .workspace(deviceID: host.deviceID(forWorkspaceID: workspaceID), workspaceID: workspaceID)
    }

    private func mutateLayout(scope: PanelScope, rerender: Bool = true, _ mutation: (PanelLayout) -> PanelLayout) {
        var state = panels[scope] ?? PanelState()
        let previousVisibility = state.layout.selectedTabID
        state.layout = mutation(state.layout)
        panels[scope] = state
        if rerender { render(scope: scope) }
        if previousVisibility != state.layout.selectedTabID {
            for tab in state.layout.tabs {
                for pane in PanelLayoutEngine.panes(in: tab) { activateContentIfVisible(scope: scope, pane: pane) }
            }
        }
        onLayoutChanged?(scope, state.layout)
        // A global panel exists only while it has content: an emptied layout (last tab
        // closed or last pane moved away) closes its window shell.
        if case .globalWindow(let panelWindowID) = scope, state.layout.isEmpty { dismissPanelWindowShell(panelWindowID: panelWindowID) }
    }

    private func render(scope: PanelScope) {
        guard let state = panels[scope], let view = state.view else { return }
        var titles: [String: String] = [:]
        for tab in state.layout.tabs { titles[tab.id] = tabTitle(forTabID: tab.id, in: state.layout) }
        view.apply(
            layout: state.layout, titlesByTabID: titles, newTabShortcutHint: host.footerShortcutHint(for: .guiOpenTerminalShortcut))
        syncPanelWindowTitle(scope: scope)
        syncFocusedPaneFooter(scope: scope)
    }
}
