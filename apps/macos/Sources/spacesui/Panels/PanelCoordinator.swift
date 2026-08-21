import AppKit
import spacesdevicecore
import spacesterminalcore

/// Owns every panel's layout, view, and pane-content lifecycle. One instance on
/// `AppKitController` (the standard unowned-host sub-controller). Invariant: a terminal
/// session has at most one pane across all panels — opening an already-open session
/// focuses its pane wherever it lives instead of creating another.
@MainActor final class PanelCoordinator {
    unowned let host: AppKitController

    init(host: AppKitController) { self.host = host }

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
    /// Live terminal content controllers keyed by session id — unchanged from before code panes
    /// existed. All of the replacement/hold machinery below is terminal-only and keys against a
    /// session id throughout, so it is left exactly as it was rather than folded into a paneID-keyed
    /// store: sessions, not panes, are what a daemon restart replaces.
    private var contentControllers: [String: any TerminalPaneContentHosting] = [:]
    /// Live code-pane content controllers keyed by pane id. A code pane has no session of its own —
    /// nothing replaces it the way a daemon restart replaces a terminal's session — so paneID is the
    /// only identity it has, and is what every code-pane lookup here keys by.
    private var codePaneControllers: [String: any PaneContentHosting] = [:]
    private var contentPreparationTasks: [String: Task<Void, Never>] = [:]
    /// Sessions the daemon closed as `awaitReplacement`: their panes are held where they are until the
    /// replacement's open claims them, so a restart's new session lands in the tab, split, and window the
    /// user arranged rather than at the end of the tab strip.
    ///
    /// Held by session id rather than by placement, because a hold has to outlive not having a pane in
    /// memory at all. The common programmatic restart is of a workspace the user is not currently
    /// viewing, whose panel was never materialized this launch: there is no in-memory pane to point at,
    /// only a persisted layout. Recording the id alone lets both pruning paths honor the hold, so the
    /// persisted pane survives until the replacement's open restores the layout and claims it in place.
    ///
    /// Exactly one of three things removes an entry: the replacement claims it, a plain teardown close
    /// releases it (which the daemon guarantees for every reservation its relaunch did not claim), or the
    /// pane is closed some other way. Both live and restore-time pruning skip a held session, because the
    /// stop deleted its row and pruning would otherwise drop the pane out from under the replacement that
    /// is on its way.
    private var panesHeldForReplacement: Set<String> = []

    /// The sessions whose panes are being held for a replacement, for the restore-time pruning that would
    /// otherwise drop them before the replacement arrives.
    var sessionIDsHeldForReplacement: Set<String> { panesHeldForReplacement }

    /// Sessions whose release arrived before their hold did.
    ///
    /// The two messages are independent IPCs, so a replacement's open can be processed before the close
    /// it replaces. If that open then fails, its release runs against a session that is not held yet, and
    /// dropping it silently would strand the hold the close is about to record: the daemon consumed the
    /// reservation when it launched the replacement, so nothing else would ever settle it. The intent is
    /// recorded here instead and the arriving hold converts straight to a teardown.
    ///
    /// An entry is cleared the moment it is consumed, by the hold it was waiting for or by a claim. The
    /// cap bounds the one case nothing consumes: a close that never arrives at all, which needs both a
    /// client-side open failure and a daemon that then died before closing. A set this size means those
    /// closes are not coming, so keeping the newest entries and dropping the rest cannot strand a
    /// replacement that is still in flight.
    private var pendingReplacementReleases: Set<String> = []

    /// Sessions whose claim arrived before their hold did, the mirror of the case above.
    ///
    /// A replacement open processed before its predecessor's close finds the predecessor still placed and
    /// retargets its pane straight away, so the pane already belongs to the replacement by the time the
    /// close lands. Without this the arriving hold would record an id whose pane has moved on, and
    /// nothing would ever settle it: the daemon considers the reservation consumed. Worse, treating that
    /// hold as ordinary and tearing it down would kill the pane the replacement is now living in, so the
    /// marker makes the late hold a pure no-op.
    ///
    /// Same lifecycle and bound as the release markers: consumed by the message it was waiting for, and
    /// capped so a close that never arrives cannot grow the set without bound.
    private var pendingReplacementClaims: Set<String> = []
    private static let pendingReplacementMarkerLimit = 64
    /// Bumped every time a pane changes which session it hosts through the replacement machinery: a
    /// held-pane or in-memory claim, and a persisted-layout/pending-window rewrite, all funnel through
    /// `noteReplacedPaneClaimed`, which is this counter's one increment site.
    ///
    /// Exists so a client-side overview apply can tell whether its data predates a pane replacement that
    /// already happened: `SidebarController` captures this value when an overview's data is captured (load
    /// start for the local snapshot, pull start or push receipt for a remote one) and compares it at apply
    /// time. A mismatch means the overview's keep-set was built before the replacement, so it cannot
    /// contain the replacement session, and pruning against it would close the pane that was just claimed.
    private(set) var paneReplacementEpoch = 0
    /// Window shells for materialized global panels, keyed by panel window id.
    private var panelWindows: [String: PanelWindowController] = [:]
    /// Runtime-target titles resolved during the current title pass (see
    /// `withRuntimeTargetTitlePass`), keyed by workspace id then session id. Empty outside a pass.
    private var runtimeTargetTitlesByWorkspaceID: [String: [String: String]] = [:]
    private var runtimeTargetTitlePassDepth = 0
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
        view.onMoveTab = { [weak self] tabID, insertionIndex in self?.moveTab(scope: scope, tabID: tabID, insertionIndex: insertionIndex) }
        view.onRenameTab = { [weak self] tabID, title in self?.renameTab(scope: scope, tabID: tabID, title: title) }
        view.onNewTab = { [weak self] in
            guard let self else { return }
            // A global panel window's "+" creates a fresh ad hoc session directly; only a
            // workspace panel's "+" (in the main window) opens the target picker.
            switch scope {
            case .workspace: self.host.presentNewTabSessionPicker(scope: scope)
            case .globalWindow: self.host.openNewTerminalTab(scope: scope)
            }
        }
        view.onSplitPane = { [weak self] paneID, direction in self?.beginSplit(scope: scope, paneID: paneID, direction: direction) }
        view.onFocusPane = { [weak self] paneID in self?.focusPane(scope: scope, paneID: paneID, moveKeyboardFocus: true) }
        view.onSplitWeightsChanged = { [weak self] splitID, weights in self?.updateSplitWeights(scope: scope, splitID: splitID, weights: weights) }
        view.paneContentProvider = { [weak self] pane in self?.content(forPane: pane) }
        view.onWindowMembershipChanged = { [weak self] isInWindow in self?.handlePanelViewWindowMembershipChanged(scope: scope, isInWindow: isInWindow) }
        panels[scope, default: PanelState()].view = view
        render(scope: scope)
        return view
    }

    /// Wired to `WorkspacePanelView.onWindowMembershipChanged`. A workspace panel stays alive detached
    /// from the window while its workspace is unselected (see that view's docstring), which is exactly
    /// what keeps a terminal pane's Ghostty surface running across workspace switches — this leaves
    /// terminal content alone entirely. A code pane's `WKWebView` is a live web process, though, and a
    /// hidden pane must hold none of those, so the panel losing its window tears down only code-pane
    /// content; the panel regaining one re-runs `activateContentIfVisible` for every pane, which rebuilds
    /// the selected tab's code pane's web view (cheap for today's placeholder) the same way it already
    /// activates a newly selected tab's content elsewhere.
    private func handlePanelViewWindowMembershipChanged(scope: PanelScope, isInWindow: Bool) {
        // A callback queued from a view teardown can arrive after this scope's panel state is gone.
        guard let state = panels[scope] else { return }
        if isInWindow {
            for tab in state.layout.tabs { for pane in PanelLayoutEngine.panes(in: tab) { activateContentIfVisible(scope: scope, pane: pane) } }
        } else {
            for tab in state.layout.tabs {
                for pane in PanelLayoutEngine.panes(in: tab) {
                    guard case .codePane = pane.content, let content = content(forPane: pane) else { continue }
                    content.deactivate()
                }
            }
        }
    }

    private func moveTab(scope: PanelScope, tabID: String, insertionIndex: Int) {
        mutateLayout(scope: scope) { PanelLayoutEngine.moveTab(tabID: tabID, toInsertionIndex: insertionIndex, in: $0) }
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

    /// Session ids occupying a pane in any panel — workspace panels and global panel
    /// windows alike. Source for the session picker's not-open-anywhere filter.
    func openSessionIDs() -> Set<String> {
        var ids: Set<String> = []
        for state in panels.values {
            for pane in PanelLayoutEngine.allPanes(in: state.layout) { if let sessionID = pane.content.terminalSessionID { ids.insert(sessionID) } }
        }
        return ids
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
                where contentControllers[sessionID]?.workspaceID == workspaceID { ordered.append(sessionID) }
            }
        }
        return ordered
    }

    func closeTerminalPanes(workspaceID: String, sessionIsTerminating: Bool = false) {
        for sessionID in openTerminalSessionIDs(workspaceID: workspaceID) {
            closePane(forSessionID: sessionID, sessionIsTerminating: sessionIsTerminating)
        }
    }

    /// Closes every open code pane matching `matches(deviceID, workspaceID)`, across all panels (a
    /// workspace panel and any global panel window). A code pane has no session for the daemon to
    /// stop, so unlike a terminal pane's close there is no `sessionIsTerminating` distinction to
    /// make: closing one is a pure local layout edit, and the caret never follows — both callers are
    /// closing a pane out from under a workspace that no longer exists, not a pane the user is
    /// looking at.
    private func closeCodePanes(where matches: (_ deviceID: String, _ workspaceID: String) -> Bool) {
        for (scope, state) in panels {
            let matchingPaneIDs = PanelLayoutEngine.allPanes(in: state.layout).compactMap { pane -> String? in
                guard case .codePane(let deviceID, let workspaceID) = pane.content, matches(deviceID, workspaceID) else { return nil }
                return pane.id
            }
            for paneID in matchingPaneIDs { removePane(scope: scope, paneID: paneID, movingKeyboardFocus: false) }
        }
    }

    /// Closes every open code pane for a workspace. Called from the same workspace-teardown
    /// chokepoint as `closeTerminalPanes` so a workspace's code pane never outlives the workspace it
    /// displays (stop, restart, and every delete path).
    func closeCodePanes(workspaceID: String) {
        closeCodePanes { _, paneWorkspaceID in paneWorkspaceID == workspaceID }
    }

    /// Closes any open code pane owned by `deviceID` whose workspace dropped out of that device's
    /// overview workspace list — the code-pane counterpart of `pruneOpenPanes`. A hidden workspace
    /// remains in the overview with `isHidden` set rather than being omitted, so an id's absence from
    /// `liveWorkspaceIDs` means the workspace record itself was deleted, not merely hidden. Call only
    /// with a successfully received overview for `deviceID`; see `pruneOpenPanes`'s contract.
    func pruneOpenCodePanes(deviceID: String, liveWorkspaceIDs: Set<String>) {
        closeCodePanes { paneDeviceID, workspaceID in paneDeviceID == deviceID && !liveWorkspaceIDs.contains(workspaceID) }
    }

    /// Cross-client lifecycle close: a workspace observed transitioning to not-running in a device's
    /// overview closes its code panes, the overview-driven counterpart of the direct-mutation
    /// `closeWorkspacePanes` path. A workspace's runtime status is per-device, so both the device id and
    /// the workspace id must match a `.codePane` descriptor's — a workspace id alone is not unique across
    /// devices.
    func closeCodePanes(deviceID: String, workspaceIDs: Set<String>) {
        closeCodePanes { paneDeviceID, workspaceID in paneDeviceID == deviceID && workspaceIDs.contains(workspaceID) }
    }

    /// Every open terminal pane's owning device and session id across all panels, read
    /// from each pane's content descriptor — the input to live overview-driven pruning.
    func openPanes() -> [OpenPanePruning.OpenPane] {
        var result: [OpenPanePruning.OpenPane] = []
        for state in panels.values {
            for pane in PanelLayoutEngine.allPanes(in: state.layout) {
                guard case .terminalSession(let deviceID, let sessionID) = pane.content else { continue }
                result.append(OpenPanePruning.OpenPane(deviceID: deviceID, sessionID: sessionID))
            }
        }
        return result
    }

    /// Closes any open pane owned by `deviceID` whose session dropped out of that device's
    /// authoritative session catalog (its product row was removed on some device, so the
    /// daemon garbage-collector will purge its transcript). The pane is torn down as an
    /// already-terminating session, so no terminate/close request is sent to the daemon for
    /// the gone session. Call only with a successfully received catalog for `deviceID`; see
    /// `OpenPanePruning.sessionsToClose`.
    /// A pane held for a replacement is skipped: the restart's stop already deleted its row, so the
    /// catalog cannot carry it, and pruning it would close the pane out from under the replacement the
    /// daemon is about to open into it.
    /// Accepted race: an overview that reflects the stop's row deletion can, in principle, be applied
    /// before the `awaitReplacement` close IPC records the hold, in which case this prunes the
    /// predecessor and the replacement installs as a fresh unselected tab instead of reclaiming the
    /// slot. That is the same fallback an app relaunch between stop and claim takes: the pane's saved
    /// position is lost, nothing else. The close IPC is posted before the deletion commits and both
    /// arrive on the same main-actor hop, so the hold wins in practice; an acknowledgment protocol to
    /// close the window entirely is not worth the coupling.
    func pruneOpenPanes(deviceID: String, catalogSessionIDs: Set<String>) {
        let sessionIDs = OpenPanePruning.sessionsToClose(openPanes: openPanes(), deviceID: deviceID, catalogSessionIDs: catalogSessionIDs)
        for sessionID in sessionIDs where !panesHeldForReplacement.contains(sessionID) {
            closePane(forSessionID: sessionID, sessionIsTerminating: true)
        }
    }

    private func scopeSortKey(_ scope: PanelScope) -> String {
        switch scope {
        case .workspace(let deviceID, let workspaceID): return "0:\(deviceID):\(workspaceID)"
        case .globalWindow(let panelWindowID): return "1:\(panelWindowID)"
        }
    }

    /// The live content controller for a session, if its pane is open anywhere.
    func content(forSessionID sessionID: String) -> (any TerminalPaneContentHosting)? { contentControllers[sessionID] }

    /// The live content controller for a code pane, by pane id — the code-pane counterpart of
    /// `content(forSessionID:)` above, since a code pane has no session to key by. Used by tests to
    /// verify a restored `.codePane` pane was rebuilt with a live controller and not merely left in the
    /// layout.
    func codePaneContent(forPaneID paneID: String) -> (any PaneContentHosting)? { codePaneControllers[paneID] }

    /// A pane's live content controller, terminal or code — the one lookup that has to work for both
    /// content kinds (the pane-view content provider, activation/visibility bookkeeping).
    private func content(forPane pane: Pane) -> (any PaneContentHosting)? {
        switch pane.content {
        case .terminalSession(_, let sessionID): return contentControllers[sessionID]
        case .codePane: return codePaneControllers[pane.id]
        }
    }

    /// The content controller owning `responder` (keyboard-routing and focus lookups). Widened to
    /// `any PaneContentHosting` so a focused code pane's web view routes the same way a focused
    /// terminal's surface does; terminal-only call sites (find actions, `sessionID`) downcast back to
    /// `TerminalPaneContentHosting` where they need it, which cleanly no-ops for a code pane instead of
    /// silently mismatching content kinds.
    func contentOwning(responder: NSResponder?) -> (any PaneContentHosting)? {
        guard let responder else { return nil }
        for controller in contentControllers.values where controller.owns(responder: responder) { return controller }
        for controller in codePaneControllers.values where controller.owns(responder: responder) { return controller }
        return nil
    }

    /// The session whose pane currently holds keyboard focus in the key window, if any. Answers nil
    /// while a code pane holds focus — it has no session id.
    func focusedSessionID() -> String? {
        (contentOwning(responder: NSApp.keyWindow?.firstResponder) as? any TerminalPaneContentHosting)?.sessionID
    }

    /// The workspace a focused code pane belongs to, if a code pane currently holds keyboard focus in
    /// the key window. The code-pane counterpart of `focusedSessionID()`, used to resolve which
    /// workspace a global panel window's "new terminal" action targets when the focused pane has no
    /// session of its own to look a workspace up from.
    func focusedCodePaneWorkspaceID() -> String? {
        guard case .codePane(_, let workspaceID) = contentOwning(responder: NSApp.keyWindow?.firstResponder)?.descriptor else { return nil }
        return workspaceID
    }

    /// The pane id of a focused code pane in the key window, if any. The palette's return-focus
    /// capture for a code pane, the code-pane counterpart of `focusedSessionID()`: a code pane has no
    /// session id for the palette to remember, so it remembers this instead.
    func focusedCodePaneID() -> String? {
        (contentOwning(responder: NSApp.keyWindow?.firstResponder) as? CodePaneContentController)?.paneID
    }

    /// Syncs the layout's focused pane to the content that actually has keyboard focus (clicks inside
    /// pane content bypass the pane chrome's mouse handling, so the app's mouse-down and key-down
    /// monitors call this to sync focus after a click or a keystroke). Works for either content kind:
    /// a terminal locates its placement by session id as before; a code pane has no session, so it is
    /// found by scanning for which paneID's controller this is.
    func noteContentFocused(_ content: any PaneContentHosting) {
        guard let (scope, paneID) = placement(forContent: content) else { return }
        guard layout(for: scope).focusedPaneID != paneID else { return }
        focusPane(scope: scope, paneID: paneID, moveKeyboardFocus: false)
    }

    private func placement(forContent content: any PaneContentHosting) -> (scope: PanelScope, paneID: String)? {
        if let terminalContent = content as? any TerminalPaneContentHosting {
            return placement(forSessionID: terminalContent.sessionID).map { (scope: $0.scope, paneID: $0.paneID) }
        }
        guard let paneID = codePaneControllers.first(where: { $0.value === content })?.key else { return nil }
        for (scope, state) in panels where PanelLayoutEngine.pane(withID: paneID, in: state.layout) != nil { return (scope, paneID) }
        return nil
    }

    // MARK: - Open / focus

    /// The unified open-or-focus behavior behind sidebar clicks, the command palette,
    /// numbered shortcuts, and cycling: focus the session's existing pane wherever it
    /// lives, else open it as a new tab in its workspace's panel.
    ///
    /// Those are two different operations where an unreachable device is concerned, and
    /// `mayActOnTerminalPane` draws the line: focusing an existing pane needs no daemon and stays
    /// available through an outage, while installing a pane the layout does not have yet is refused
    /// — before the layout is mutated and persisted — because it can only work by attaching to the
    /// owning daemon.
    ///
    /// `openIntent.focus` crosses that line rather than replacing it: a `.withoutFocus` open still
    /// installs a missing pane (and is still refused when the device cannot service it), it just leaves
    /// the panel's selection, ordering, and keyboard focus untouched. `openIntent.replacesSessionID`
    /// claims the named session's pane instead of installing a second one.
    /// Answers what it did, not merely that it worked, because the caller has to tell a real claim from a
    /// fallback install: an open that installed a fresh pane leaves any hold on its named predecessor
    /// untouched and still owing a release. Nil means the open failed.
    @discardableResult func openOrFocusTerminalPane(_ request: AppKitController.DeviceTerminalOpenRequest, openIntent: TerminalPaneOpenIntent)
        -> AppKitController.TerminalPaneOpenAction?
    {
        let focusIntent = openIntent.focus
        // Adopt the workspace's persisted layout first: on a fresh launch a session
        // opened before its panel was ever shown (command palette, focus IPC) is not
        // yet in an in-memory panel, so without this the placement search misses it and
        // openSessionInNewTab would overwrite the saved tabs/splits with a one-tab layout.
        // It also decides which of the two operations below this is: a persisted pane is an
        // existing one, so a cold launch focuses it instead of trying to install a second.
        // The restore materializes content controllers of its own, whose preparation completes
        // asynchronously, so it inherits this open's intent: a non-focusing open must not move the caret
        // through the panel it had to adopt on the way in either.
        // The restore protects this open's own predecessor: processed before that session's close, there is
        // no hold recorded yet, and the stop already dropped its row from the overview, so an unprotected
        // restore would prune the very pane this open is about to claim.
        if let scope = workspaceScope(forWorkspaceID: request.workspaceID) {
            restoreLayoutIfNeeded(scope: scope, focusIntent: focusIntent, protectingSessionID: openIntent.replacesSessionID)
        }
        let existingPlacement = placement(forSessionID: request.sessionID)
        // The pane this open takes over, if the launch named a predecessor that still occupies one. Read
        // from the layout rather than from the held-pane table, so the claim works whichever order the
        // close and the open IPCs arrive in: the close having landed first leaves the pane held and still
        // placed, and the open landing first finds it still placed and simply retargets it, after which
        // the late close finds no placement for the predecessor and does nothing.
        let replacedPlacement = openIntent.replacesSessionID.flatMap { placement(forSessionID: $0) }
        guard mayActOnTerminalPane(request: request, existingPlacement: existingPlacement, focusIntent: focusIntent) else { return nil }
        switch AppKitController.terminalPaneOpenAction(
            hasExistingPane: existingPlacement != nil, hasReplaceablePane: replacedPlacement != nil, focusIntent: focusIntent)
        {
        case .focusExistingPane:
            // Reached only when `hasExistingPane` was true, so the placement is there.
            if let existingPlacement { focus(placement: existingPlacement) }
            return .focusExistingPane
        // The session re-targets into the pane it already occupies; nothing to install, nothing to move.
        case .leaveExistingPaneInPlace: return .leaveExistingPaneInPlace
        case .claimReplacedPane:
            // Reached only when `hasReplaceablePane` was true, so both are there.
            guard let replacedSessionID = openIntent.replacesSessionID, let replacedPlacement else { return nil }
            return claimReplacedPane(replacedSessionID: replacedSessionID, placement: replacedPlacement, request: request, focusIntent: focusIntent)
                ? .claimReplacedPane : nil
        case .openFocusedTab: return openSessionInNewTab(request) ? .openFocusedTab : nil
        case .installUnselectedTab:
            // A predecessor whose pane lives in a global panel window still waiting on an offline device
            // has no in-memory placement to claim, and installing a workspace tab here would leave that
            // window's saved slot to be pruned when it finally restores. Retarget the pending record's
            // persisted layout instead, which is the same retarget applied to the representation the pane
            // currently lives in, and install nothing: the pane reappears with the window, in its slot.
            //
            // Not gated on a hold being recorded: the same open-before-close ordering reaches here too, and
            // the named predecessor is the only precondition that matters. `replacesSessionID` is set by a
            // restart and nothing else, so a pending record naming it is always the pane to take over.
            if let replacedSessionID = openIntent.replacesSessionID,
                host.retargetPendingPanelWindowPane(replacing: replacedSessionID, with: paneContentDescriptor(for: request))
            {
                noteReplacedPaneClaimed(replacedSessionID)
                return .claimReplacedPane
            }
            return installSessionInUnselectedTab(request) ? .installUnselectedTab : nil
        }
    }

    /// The descriptor a request's pane would carry, resolved without building any content: the pending
    /// global-window retarget rewrites a persisted layout the client is not hosting yet, so it needs the
    /// descriptor alone.
    private func paneContentDescriptor(for request: AppKitController.DeviceTerminalOpenRequest) -> PaneContentDescriptor {
        .terminalSession(deviceID: request.deviceID ?? host.deviceID(forWorkspaceID: request.workspaceID) ?? "", sessionID: request.sessionID)
    }

    /// Points a runtime target's replacement at the pane its predecessor occupied, when the pairing
    /// reaches this client as an overview diff instead of as the replacement's own open.
    ///
    /// Every start and restart of a runtime target is served by the Device API, whose orchestrator has no
    /// opener to any client, so `openOrFocusTerminalPane`'s claim route is never reached for one. The
    /// device's refreshed overview names the same pairing (`TerminalSessionReplacementDiff`), and this
    /// applies it: the pane keeps its tab, its position in any split, and its window, and starts showing
    /// the replacement instead of the ended session's last frame.
    ///
    /// Deliberately never installs a pane. Only a predecessor that has one — placed, held, restorable
    /// from a persisted workspace layout, or waiting inside a panel window whose device has not connected
    /// yet — hands it over; a target restarted with no pane open stays with no pane, where the open path
    /// would have installed one.
    ///
    /// A hold placed by the predecessor's `awaitReplacement` close always ends here, since this is the
    /// last thing the client will hear about that restart. A remote device's daemon posts no close at
    /// all, so there is never a hold for a remote restart: the predecessor's pane is found the same way a
    /// held one is, by checking whether it is already placed, restoring it from a persisted workspace
    /// layout, or finding it in a pending panel window record — none of which needs a hold on record.
    @discardableResult func retargetPaneForReplacement(replacedSessionID: String, request: AppKitController.DeviceTerminalOpenRequest) -> Bool {
        let wasHeld = panesHeldForReplacement.contains(replacedSessionID)
        guard placement(forSessionID: request.sessionID) == nil else {
            // The replacement already has a pane of its own, so the predecessor's is not its to take.
            // Checked first, before any restore attempt below, so a predecessor that turns out to be
            // unclaimable is never speculatively materialized for nothing.
            panesHeldForReplacement.remove(replacedSessionID)
            return false
        }
        // A predecessor with no pane behind it is the ordinary shape for a workspace whose panel has not
        // been shown this launch: the pane exists only in the persisted layout, and claiming it needs
        // that layout materialized first, exactly as the replacement's open would have restored it. Not
        // gated on `wasHeld`: a remote device's restart never records one, and the same persisted-only gap
        // shows up there too.
        if placement(forSessionID: replacedSessionID) == nil, let scope = workspaceScope(forWorkspaceID: request.workspaceID) {
            restoreLayoutIfNeeded(scope: scope, focusIntent: .withoutFocus, protectingSessionID: replacedSessionID)
        }
        if let replacedPlacement = placement(forSessionID: replacedSessionID) {
            if claimReplacedPane(replacedSessionID: replacedSessionID, placement: replacedPlacement, request: request, focusIntent: .withoutFocus) {
                return true
            }
            // The replacement could not be attached, so this pane cannot become the terminal it is being
            // kept for. Close it as the terminating close the hold deferred.
            if wasHeld { closePane(forSessionID: replacedSessionID, sessionIsTerminating: true, disposition: .teardown) }
            return false
        }
        // No in-memory or restored-workspace placement: the other persisted home for a predecessor's pane
        // is a global panel window still waiting on its device. Retarget the pending record so the pane
        // comes back pointed at the replacement, in its saved slot. Reached whether or not a hold was
        // recorded; a session id with no home in any of the above is absent here too and falls through to
        // `false`.
        if host.retargetPendingPanelWindowPane(replacing: replacedSessionID, with: paneContentDescriptor(for: request)) {
            noteReplacedPaneClaimed(replacedSessionID)
            return true
        }
        panesHeldForReplacement.remove(replacedSessionID)
        return false
    }

    /// Points a predecessor's pane at the replacement session, keeping its tab, its position in any
    /// split, and its window. Nothing is selected, brought forward, or focused: a replacement lands in
    /// the pane the user already had, and if that pane happened to be the visible one it simply starts
    /// showing the new session.
    private func claimReplacedPane(
        replacedSessionID: String, placement: PanePlacement, request: AppKitController.DeviceTerminalOpenRequest, focusIntent: TerminalOpenFocusIntent
    ) -> Bool {
        guard let content = ensureContentController(request: request, focusIntent: focusIntent) else { return false }
        noteReplacedPaneClaimed(replacedSessionID)
        // Read before the swap: tearing the predecessor's view out takes the first responder with it, so
        // afterwards there is no way to tell the user was typing in this pane.
        let replacedHeldKeyboardFocus =
            NSApp.keyWindow?.firstResponder.map { contentControllers[replacedSessionID]?.owns(responder: $0) ?? false } ?? false
        // Tear the predecessor's client down now rather than at close time: holding the pane kept its
        // ended output on screen through the relaunch, and this is the moment that output is replaced.
        if let previous = contentControllers.removeValue(forKey: replacedSessionID) {
            contentPreparationTasks.removeValue(forKey: replacedSessionID)?.cancel()
            previous.closeForSessionTermination()
        }
        mutateLayout(scope: placement.scope) { PanelLayoutEngine.retargetPane(paneID: placement.paneID, to: content.descriptor, in: $0) }
        if let pane = PanelLayoutEngine.pane(withID: placement.paneID, in: layout(for: placement.scope)) {
            activateContentIfVisible(scope: placement.scope, pane: pane)
        }
        // A replacement that is still preparing takes the caret on its placeholder; the preparation
        // completion then carries it across the second swap by the same rule.
        if AppKitController.terminalPaneRetargetMovesKeyboardFocusToReplacement(replacedPaneHoldsKeyboardFocus: replacedHeldKeyboardFocus) {
            _ = content.makeContentFirstResponder()
        }
        return true
    }

    /// Holds a pane for the replacement the daemon is about to launch, instead of tearing it down. A
    /// materialized pane keeps showing the ended session's final output until the replacement claims it;
    /// a workspace whose panel has never been shown this launch has only its persisted layout, and the
    /// hold is what keeps restore-time pruning from dropping that pane before the replacement arrives to
    /// claim it. Deliberately does not require a placement, since the second case has none.
    private func holdPaneForReplacement(sessionID: String) { panesHeldForReplacement.insert(sessionID) }

    /// Tears down a pane whose replacement never arrived, as the ordinary terminating close it would have
    /// been had the restart not asked for the hold: the session is already stopped, so the caret stays
    /// where it is. Acting only on a pane that is genuinely held makes this safe to call on any path out
    /// of a failed open, including ones where the replacement did claim the pane or where no hold was
    /// ever placed.
    func releasePaneHeldForReplacement(sessionID: String) {
        // An earlier open already claimed this predecessor, so its pane belongs to the replacement now
        // and there is nothing of the predecessor's left to release. Clearing the marker settles it.
        if pendingReplacementClaims.remove(sessionID) != nil { return }
        guard panesHeldForReplacement.contains(sessionID) else {
            // Nothing held yet: this release beat the close that will place the hold. Remember the
            // intent so that hold converts to a teardown on arrival instead of waiting for a settling
            // message the daemon has already stopped sending.
            recordPendingReplacementMarker(sessionID, in: &pendingReplacementReleases)
            return
        }
        closePane(forSessionID: sessionID, sessionIsTerminating: true, disposition: .teardown)
    }

    /// Settles a predecessor whose pane a replacement just took over, from either claim route (an
    /// in-memory retarget, or a pending global window's persisted layout).
    ///
    /// A claim with nothing held is a claim that beat its close: the predecessor was still placed because
    /// the hold has not arrived yet. Remembering that makes the late close a no-op instead of a hold for a
    /// pane that has already moved on. Both routes go through here so the marker cannot be recorded by one
    /// of them and forgotten by the other.
    private func noteReplacedPaneClaimed(_ replacedSessionID: String) {
        let wasHeld = panesHeldForReplacement.remove(replacedSessionID) != nil
        pendingReplacementReleases.remove(replacedSessionID)
        if !wasHeld { recordPendingReplacementMarker(replacedSessionID, in: &pendingReplacementClaims) }
        paneReplacementEpoch += 1
    }

    /// Records an out-of-order marker, dropping the set when it grows past the point where its entries
    /// could still be waiting on a message that is coming. Both marker sets share this so their
    /// lifecycle, and the reasoning behind the bound, stay in one place.
    /// Accepted at the bound: clearing discards any marker whose close really is still in flight, and
    /// a discarded claim's late `awaitReplacement` then records a hold nothing will release, keeping a
    /// dead pane until the app relaunches (holds are not persisted, so relaunch prunes it). Reaching
    /// the bound takes that many restarts each losing the close/claim race at once, which does not
    /// happen under real usage; the bound exists so a peer that stops sending closes cannot grow the
    /// sets without limit.
    private func recordPendingReplacementMarker(_ sessionID: String, in markers: inout Set<String>) {
        if markers.count >= Self.pendingReplacementMarkerLimit { markers.removeAll() }
        markers.insert(sessionID)
    }

    /// Re-shows a session whose pane is already the focused, owner-attached pane the user is looking at:
    /// brings its panel forward and puts the caret back, and nothing else. Answers false — leaving the
    /// caller on the full open path — for every other case, so a pane that is not focused, is on an
    /// unselected tab, or whose session another client owns still gets its state refresh, attach, and
    /// ownership reclaim.
    ///
    /// Skipping the rest is safe only because this pane already holds the owner attachment: the state
    /// fetch, attach, and reclaim the open path would run are exactly the work that established that, and
    /// re-running them against an unchanged attachment is what made every warm terminal switch pay two
    /// no-op viewport resizes and a full render-frame export.
    func refocusFocusedTerminalPane(forSessionID sessionID: String) -> Bool {
        guard let placement = placement(forSessionID: sessionID), let content = contentControllers[sessionID] else { return false }
        let layout = layout(for: placement.scope)
        guard
            AppKitController.canRefocusTerminalPaneWithoutReattaching(
                paneIsFocused: layout.focusedPaneID == placement.paneID, paneIsInSelectedTab: layout.selectedTabID == placement.tabID,
                paneHoldsOwnerAttachedSurface: content.holdsOwnerAttachedSurface)
        else { return false }
        host.showPanelScope(placement.scope)
        host.noteWindowNavigationTerminalFocus(sessionID: sessionID)
        content.makeContentFirstResponder()
        return true
    }

    /// Whether the layout may act on `request`, refusing — with the reason, naming the device — a
    /// request that would have to install a pane for a daemon that cannot be attached to. Every door a
    /// user action can install a pane through asks this first: opening it as a tab, moving it into its
    /// own window, or filling a split. It has to answer before the install rather than during it,
    /// because installing appends the pane to the layout and persists it before credentials are
    /// prepared, so an admitted pane is saved as a permanently failed one that no reconnect retries.
    /// Moving or focusing a pane that already exists is client-side and always allowed.
    /// - Parameter focusIntent: Decides how a refusal is reported. The install doors a user drives (a new
    ///   tab, a move to its own window, filling a split) are always focusing and owe the user a modal; a
    ///   programmatic launch refused because its device went unreachable must not interrupt them.
    private func mayActOnTerminalPane(
        request: AppKitController.DeviceTerminalOpenRequest, existingPlacement: PanePlacement?, focusIntent: TerminalOpenFocusIntent
    ) -> Bool {
        guard
            AppKitController.canOpenOrFocusTerminalPane(
                hasExistingPane: existingPlacement != nil,
                deviceAcceptsDaemonActions: host.deviceAcceptsDaemonActions(forTerminalOpenRequest: request))
        else {
            host.showTerminalOpenRequestDeviceUnavailableError(request, focusIntent: focusIntent)
            return false
        }
        return true
    }

    /// Opens the session as a new tab — in its workspace's panel by default (the
    /// cmd+opt+t landing path for a freshly created session), or in an explicit scope
    /// (a global panel window's "+" button).
    @discardableResult func openSessionInNewTab(_ request: AppKitController.DeviceTerminalOpenRequest, in scope: PanelScope? = nil) -> Bool {
        guard let resolvedScope = scope ?? workspaceScope(forWorkspaceID: request.workspaceID) else { return false }
        guard let content = ensureContentController(request: request, focusIntent: .focus) else { return false }
        let pane = Pane(id: UUID().uuidString, content: content.descriptor)
        mutateLayout(scope: resolvedScope) { PanelLayoutEngine.appendTab(tabID: UUID().uuidString, pane: pane, to: $0) }
        host.showPanelScope(resolvedScope)
        activateFocusedPane(scope: resolvedScope)
        return true
    }

    /// Installs a session as a new tab in its workspace's panel without selecting it, without bringing
    /// the panel forward, and without touching keyboard focus: the pane a programmatically launched
    /// process lands in, waiting on an unselected tab until the user goes looking for it.
    ///
    /// The one exception is a panel that had no tabs at all, where the layout normalizer selects the
    /// first tab because a panel must always show one. That still moves nothing the user was using: the
    /// panel had nothing to show, and it is not brought forward or focused either way.
    private func installSessionInUnselectedTab(_ request: AppKitController.DeviceTerminalOpenRequest) -> Bool {
        guard let scope = workspaceScope(forWorkspaceID: request.workspaceID) else { return false }
        guard let content = ensureContentController(request: request, focusIntent: .withoutFocus) else { return false }
        let pane = Pane(id: UUID().uuidString, content: content.descriptor)
        mutateLayout(scope: scope) { PanelLayoutEngine.appendUnselectedTab(tabID: UUID().uuidString, pane: pane, to: $0) }
        // Matches how a restored layout activates its panes: visible content runs, hidden content stays
        // parked. Without this the freshly built controller is left in neither state.
        activateContentIfVisible(scope: scope, pane: pane)
        return true
    }

    /// Adopts a persisted layout for a workspace panel the first time it is shown,
    /// materializing content controllers for its still-live sessions.
    ///
    /// `focusIntent` is the intent of whatever caused the adoption, carried down to the restored panes'
    /// asynchronous preparation.
    /// - Parameter protectingSessionID: A predecessor the adopting open is about to claim, kept out of the
    ///   restoration prune even when no hold has been recorded for it yet.
    func restoreLayoutIfNeeded(scope: PanelScope, focusIntent: TerminalOpenFocusIntent, protectingSessionID: String? = nil) {
        guard panels[scope] == nil, case .workspace(let deviceID, let workspaceID) = scope,
            let layout = host.restoredWorkspacePanelLayout(
                deviceID: deviceID, workspaceID: workspaceID, additionalKeepSessionIDs: protectingSessionID.map { [$0] } ?? []), !layout.isEmpty
        else { return }
        panels[scope] = PanelState(layout: layout, view: nil)
        for pane in PanelLayoutEngine.allPanes(in: layout) {
            switch pane.content {
            case .terminalSession:
                guard let sessionID = pane.content.terminalSessionID, contentControllers[sessionID] == nil,
                    let request = host.paneOpenRequest(workspaceID: workspaceID, sessionID: sessionID)
                else { continue }
                _ = ensureContentController(request: request, focusIntent: focusIntent)
            case .codePane(let paneDeviceID, let paneWorkspaceID):
                installCodePaneController(paneID: pane.id, deviceID: paneDeviceID, workspaceID: paneWorkspaceID)
            }
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
        let existingPlacement = placement(forSessionID: request.sessionID)
        // A session with no pane yet would have one installed here — and persisted as a `panel_windows`
        // row — for a daemon that cannot be attached to.
        guard mayActOnTerminalPane(request: request, existingPlacement: existingPlacement, focusIntent: .focus) else { return }
        if let existing = existingPlacement {
            if case .globalWindow = existing.scope, isLonePane(scope: existing.scope) {
                focus(placement: existing)
                return
            }
            mutateLayout(scope: existing.scope) { PanelLayoutEngine.removePane(paneID: existing.paneID, from: $0) }
        }
        guard let content = ensureContentController(request: request, focusIntent: .focus) else { return }
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

    /// Reopens a persisted global panel window at startup: adopts the (already pruned)
    /// layout, materializes content controllers for its sessions, and shows the shell
    /// at its saved frame without stealing focus.
    func restorePanelWindow(panelWindowID: String, layout: PanelLayout, frame: NSRect?) {
        let scope = PanelScope.globalWindow(panelWindowID: panelWindowID)
        guard panels[scope] == nil else { return }
        panels[scope] = PanelState(layout: layout, view: nil)
        for pane in PanelLayoutEngine.allPanes(in: layout) {
            switch pane.content {
            case .terminalSession:
                guard let sessionID = pane.content.terminalSessionID, contentControllers[sessionID] == nil else { continue }
                guard let workspaceID = host.clientWorkspaceID(forTerminalSession: sessionID),
                    let request = host.paneOpenRequest(workspaceID: workspaceID, sessionID: sessionID)
                else { continue }
                // `.focus`: a restored window re-activates its focused pane when preparation completes,
                // and the shell is shown without becoming key, so that re-activation stays inside this
                // window instead of taking the caret from the one the user is in. The no-steal promise
                // above is the shell's, not the panes'.
                _ = ensureContentController(request: request, focusIntent: .focus)
            case .codePane(let deviceID, let workspaceID): installCodePaneController(paneID: pane.id, deviceID: deviceID, workspaceID: workspaceID)
            }
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

    /// Focuses a code pane's existing placement, if it still has one — the code-pane counterpart of
    /// `focusPane(forSessionID:)` used to restore the command palette's return focus. A code pane has
    /// no session to look up by, so this scans every panel for the pane id directly.
    @discardableResult func focusPane(forCodePaneID paneID: String) -> Bool {
        for (scope, state) in panels {
            for tab in state.layout.tabs {
                for pane in PanelLayoutEngine.panes(in: tab) where pane.id == paneID {
                    guard case .codePane = pane.content else { continue }
                    focus(placement: PanePlacement(scope: scope, tabID: tab.id, paneID: pane.id))
                    return true
                }
            }
        }
        return false
    }

    func focusPane(scope: PanelScope, paneID: String, moveKeyboardFocus: Bool) {
        mutateLayout(scope: scope) { PanelLayoutEngine.focusPane(paneID: paneID, in: $0) }
        if moveKeyboardFocus { activateFocusedPane(scope: scope) }
    }

    /// Restores a workspace panel's remembered focus when the sidebar selection lands
    /// on it (arrow-key workspace switching), without stealing keyboard focus from the
    /// sidebar.
    func restoreSelection(scope: PanelScope) {
        for tab in layout(for: scope).tabs { for pane in PanelLayoutEngine.panes(in: tab) { activateContentIfVisible(scope: scope, pane: pane) } }
        render(scope: scope)
    }

    private func activateFocusedPane(scope: PanelScope) {
        let layout = layout(for: scope)
        guard let focusedPaneID = layout.focusedPaneID, let pane = PanelLayoutEngine.pane(withID: focusedPaneID, in: layout),
            let content = content(forPane: pane)
        else { return }
        if let sessionID = pane.content.terminalSessionID { host.noteWindowNavigationTerminalFocus(sessionID: sessionID) }
        content.activate(focus: true)
    }

    private func activateContentIfVisible(scope: PanelScope, pane: Pane) {
        guard let content = content(forPane: pane) else { return }
        let layout = layout(for: scope)
        let isInSelectedTab =
            layout.tabs.first { $0.id == layout.selectedTabID }.map { PanelLayoutEngine.panes(in: $0).contains { $0.id == pane.id } } ?? false
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

    /// A user closing a pane (its close button, `Cmd+W`, dragging it away): the caret follows to
    /// whichever pane takes its place, because the user is working in this panel.
    func closePane(scope: PanelScope, paneID: String) { removePane(scope: scope, paneID: paneID, movingKeyboardFocus: true) }

    /// Removes a pane and, only when the close came from the user, hands the caret to the pane the
    /// layout focuses next. The remaining panes are activated either way: `mutateLayout` re-activates
    /// them whenever the removal changed which tab is selected, so a pane that becomes visible still
    /// runs. Withholding the caret withholds exactly that and nothing else.
    private func removePane(scope: PanelScope, paneID: String, movingKeyboardFocus: Bool) {
        if let pane = PanelLayoutEngine.pane(withID: paneID, in: layout(for: scope)) {
            // A pane the user closed while it was being held for a replacement takes the hold with it, so
            // the table cannot outlive the pane it describes.
            if let sessionID = pane.content.terminalSessionID { panesHeldForReplacement.remove(sessionID) }
            closeContent(for: pane)
        }
        mutateLayout(scope: scope) { PanelLayoutEngine.removePane(paneID: paneID, from: $0) }
        guard movingKeyboardFocus else { return }
        activateFocusedPane(scope: scope)
    }

    /// Closes a session's pane wherever it lives. `sessionIsTerminating` marks a
    /// daemon-driven close (the session is already stopping), so the client detach —
    /// and with it the attachment-driven unattached ad hoc cleanup — is skipped.
    ///
    /// It also marks a close the user did not ask for, which is why it decides whether the caret moves:
    /// a stop, a restart, an exited process, or a pruned session must not pull focus out of wherever the
    /// user is and into a terminal. A programmatic `workspace restart` closes every one of a workspace's
    /// panes in a row, so the alternative is the caret hopping through each survivor in turn.
    func closePane(forSessionID sessionID: String, sessionIsTerminating: Bool = false, disposition: TerminalPaneCloseDisposition = .teardown) {
        // Every close by session id ends this session, so its in-flight content preparation is work for a
        // session that is already gone. Cancelled here, once, ahead of the disposition branch: a hold
        // keeps the pane but not the session, and a preparation left running would land after the stop
        // and, carrying the original open's intent, move the caret or raise a failure modal for a
        // terminal that no longer exists.
        contentPreparationTasks.removeValue(forKey: sessionID)?.cancel()
        if disposition == .awaitReplacement {
            switch AppKitController.terminalPaneHoldAction(
                hasPendingClaim: pendingReplacementClaims.contains(sessionID), hasPendingRelease: pendingReplacementReleases.contains(sessionID))
            {
            case .consumeClaim:
                pendingReplacementClaims.remove(sessionID)
                return
            case .hold:
                // Recorded before the placement lookup: the workspace being restarted is usually one the
                // user is not viewing, whose panel has no in-memory pane to find, and the hold is exactly
                // what protects its persisted pane until the replacement claims it.
                holdPaneForReplacement(sessionID: sessionID)
                return
            // Falls through to the ordinary teardown below.
            case .teardown: break
            }
        }
        pendingReplacementReleases.remove(sessionID)
        panesHeldForReplacement.remove(sessionID)
        guard let placement = placement(forSessionID: sessionID) else { return }
        if sessionIsTerminating, let content = contentControllers.removeValue(forKey: sessionID) { content.closeForSessionTermination() }
        removePane(
            scope: placement.scope, paneID: placement.paneID,
            movingKeyboardFocus: AppKitController.terminalPaneCloseMovesKeyboardFocus(sessionIsTerminating: sessionIsTerminating))
    }

    /// Detaches every open pane's terminal client at app termination without stopping
    /// sessions (daemon-owned sessions keep running across quit; panes are rebuilt on
    /// relaunch from the persisted layout).
    func closeAllContentForTermination() {
        for task in contentPreparationTasks.values { task.cancel() }
        contentPreparationTasks.removeAll()
        for content in contentControllers.values { content.close() }
        for content in codePaneControllers.values { content.close() }
    }

    /// Re-themes every open pane's live session to the app's current light/dark appearance. Called when the
    /// app appearance changes (`AppKitController.applyAppAppearance`) so open terminals — local and remote —
    /// recolor within a frame or two. Each pane dedupes against its own last-applied appearance, so a session
    /// already on `appearance` sends nothing.
    func broadcastAppearance(_ appearance: ThemeAppearance) { for content in contentControllers.values { content.applyAppearance(appearance) } }

    /// Re-renders every open pane's terminal content at the app-wide terminal text size. One value is
    /// shared by every pane, so a zoom in the focused pane resizes the text in all of them, not only
    /// in panes opened afterwards.
    func broadcastTerminalTextSize(_ size: TerminalTextSize) { for content in contentControllers.values { content.applyTerminalTextSize(size) } }

    private func closeContent(for pane: Pane) {
        switch pane.content {
        case .terminalSession:
            guard let sessionID = pane.content.terminalSessionID, let content = contentControllers.removeValue(forKey: sessionID) else { return }
            contentPreparationTasks.removeValue(forKey: sessionID)?.cancel()
            // Live terminal content asks for the conditional ad hoc stop through its close-detach hook,
            // reporting whether it held ownership. A preparing placeholder has no embedded client to
            // detach and so holds no attachment at all, but the daemon shell already exists: the
            // placeholder was opened to own it, and with no attachment of its own to lose it asks
            // unconditionally. The daemon still keeps the session whenever another client holds a live
            // owner attachment.
            content.close()
            if content is TerminalPanePlaceholderContentController {
                host.stopAdHocBuiltInTerminalSessionIfBareShell(sessionID: sessionID, closedPaneOwnedOrEnded: true)
            }
        case .codePane:
            // No daemon-side session to detach: a code pane is client-only, so closing its content is
            // the whole teardown.
            codePaneControllers.removeValue(forKey: pane.id)?.close()
        }
    }

    private func beginSplit(scope: PanelScope, paneID: String, direction: PaneSplitDirection) {
        // "New terminal session" targets the split pane's own workspace (which is the
        // panel's workspace for a workspace scope, and the source pane's for global).
        let sourceWorkspaceID: String?
        switch PanelLayoutEngine.pane(withID: paneID, in: layout(for: scope))?.content {
        case .terminalSession(_, let sessionID): sourceWorkspaceID = contentControllers[sessionID]?.workspaceID
        case .codePane(_, let workspaceID): sourceWorkspaceID = workspaceID
        case nil: sourceWorkspaceID = nil
        }
        let newTerminalWorkspaceID: String
        switch scope {
        case .workspace(_, let workspaceID): newTerminalWorkspaceID = sourceWorkspaceID ?? workspaceID
        case .globalWindow:
            guard let sourceWorkspaceID else { return }
            newTerminalWorkspaceID = sourceWorkspaceID
        }
        host.presentPaneSessionPicker(scope: scope, newTerminalWorkspaceID: newTerminalWorkspaceID) { [weak self] result in
            guard let self, let result else { return }
            switch result {
            case .terminal(let request): self.fillSplit(scope: scope, paneID: paneID, direction: direction, request: request)
            case .codePane(let deviceID, let workspaceID, let mode):
                self.fillSplitWithCodePane(scope: scope, paneID: paneID, direction: direction, deviceID: deviceID, workspaceID: workspaceID, mode: mode)
            }
        }
    }

    private func fillSplit(scope: PanelScope, paneID: String, direction: PaneSplitDirection, request: AppKitController.DeviceTerminalOpenRequest) {
        // The picker no longer offers sessions that are already open, so this branch
        // isn't the normal path here — it only guards the race where a session opens
        // elsewhere (sidebar click, IPC) while the picker is up, preserving the
        // one-pane-per-session invariant. Picking the source pane's own session is a
        // no-op: removing it first would leave splitPane with no paneID to split,
        // orphaning the session's pane and its content controller.
        let existingPlacement = placement(forSessionID: request.sessionID)
        // A picked target whose session is not open anywhere would have its pane installed here, so the
        // split obeys the same rule the other install doors do.
        guard mayActOnTerminalPane(request: request, existingPlacement: existingPlacement, focusIntent: .focus) else { return }
        if let existing = existingPlacement {
            guard existing.paneID != paneID else { return }
            mutateLayout(scope: existing.scope) { PanelLayoutEngine.removePane(paneID: existing.paneID, from: $0) }
        }
        guard let content = ensureContentController(request: request, focusIntent: .focus) else { return }
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

    // MARK: - Code panes

    /// Focuses the workspace's existing code pane wherever it lives — its own panel first, then global
    /// panel windows — or opens a fresh one in `mode` in the workspace's own panel when none is open
    /// anywhere — the "Review changes" shortcut's action. Mirrors the terminal convention
    /// (`placement(forSessionID:)`, `openOrFocusTerminalPane`): a code pane opened via the split/new-tab
    /// picker in a global panel window, or restored there at startup, is the same pane as one opened from
    /// this shortcut, so the shortcut must find and focus it instead of installing a duplicate.
    @discardableResult func openOrFocusCodePane(deviceID: String, workspaceID: String, mode: CodePaneMode) -> Bool {
        guard let scope = workspaceScope(forWorkspaceID: workspaceID) else { return false }
        restoreLayoutIfNeeded(scope: scope, focusIntent: .focus)
        if let placement = codePanePlacement(deviceID: deviceID, workspaceID: workspaceID) {
            focus(placement: placement)
            return true
        }
        return openCodePaneInNewTab(deviceID: deviceID, workspaceID: workspaceID, initialMode: mode, in: scope)
    }

    /// Where a workspace's code pane lives across every panel scope, if it is open anywhere. Scopes are
    /// searched in `scopeSortKey` order so the workspace's own panel wins over a global panel window when
    /// (in principle) more than one is open, and the result is otherwise deterministic.
    private func codePanePlacement(deviceID: String, workspaceID: String) -> PanePlacement? {
        for (scope, state) in panels.sorted(by: { scopeSortKey($0.key) < scopeSortKey($1.key) }) {
            for tab in state.layout.tabs {
                for pane in PanelLayoutEngine.panes(in: tab) {
                    guard case .codePane(let paneDeviceID, let paneWorkspaceID) = pane.content, paneDeviceID == deviceID,
                        paneWorkspaceID == workspaceID
                    else { continue }
                    return PanePlacement(scope: scope, tabID: tab.id, paneID: pane.id)
                }
            }
        }
        return nil
    }

    /// Opens a fresh code pane as a new tab in the workspace's panel (the "Diff" and "Open file…"
    /// picker rows), in its workspace's panel by default or an explicit scope (mirrors
    /// `openSessionInNewTab`).
    @discardableResult func openCodePaneInNewTab(
        deviceID: String, workspaceID: String, initialMode: CodePaneMode, in scope: PanelScope? = nil
    ) -> Bool {
        guard let resolvedScope = scope ?? workspaceScope(forWorkspaceID: workspaceID) else { return false }
        let paneID = UUID().uuidString
        let content = installCodePaneController(paneID: paneID, deviceID: deviceID, workspaceID: workspaceID, initialMode: initialMode)
        let pane = Pane(id: paneID, content: content.descriptor)
        mutateLayout(scope: resolvedScope) { PanelLayoutEngine.appendTab(tabID: UUID().uuidString, pane: pane, to: $0) }
        host.showPanelScope(resolvedScope)
        activateFocusedPane(scope: resolvedScope)
        return true
    }

    /// Fills a split with a fresh code pane, the code-pane counterpart of `fillSplit`.
    private func fillSplitWithCodePane(
        scope: PanelScope, paneID: String, direction: PaneSplitDirection, deviceID: String, workspaceID: String, mode: CodePaneMode
    ) {
        let newPaneID = UUID().uuidString
        let content = installCodePaneController(paneID: newPaneID, deviceID: deviceID, workspaceID: workspaceID, initialMode: mode)
        let pane = Pane(id: newPaneID, content: content.descriptor)
        mutateLayout(scope: scope) { layout in
            PanelLayoutEngine.splitPane(paneID: paneID, direction: direction, newPane: pane, newSplitID: UUID().uuidString, in: layout) ?? layout
        }
        activateFocusedPane(scope: scope)
    }

    /// Builds (or returns the already-live) controller for a code pane, keyed by pane id since a code
    /// pane has no session to key by. Idempotent so restore paths can call it unconditionally: a pane
    /// id already backed by a live controller (e.g. a panel adopted twice) is left untouched rather
    /// than losing its in-flight web view.
    @discardableResult private func installCodePaneController(
        paneID: String, deviceID: String, workspaceID: String, initialMode: CodePaneMode = .diff
    ) -> any PaneContentHosting {
        if let existing = codePaneControllers[paneID] { return existing }
        let content = CodePaneContentController(paneID: paneID, deviceID: deviceID, workspaceID: workspaceID, initialMode: initialMode)
        codePaneControllers[paneID] = content
        return content
    }

    // MARK: - Content lifecycle

    /// - Parameter focusIntent: The intent of the open that needs this content, carried into the
    ///   asynchronous preparation so its completion knows whether it may move the caret.
    private func ensureContentController(request: AppKitController.DeviceTerminalOpenRequest, focusIntent: TerminalOpenFocusIntent) -> (
        any TerminalPaneContentHosting
    )? {
        if let existing = contentControllers[request.sessionID] { return existing }
        if request.preparedCredentials == nil {
            // The placeholder holds the device its pane will connect to; with no known owner
            // there is nothing to connect to, so no pane opens.
            guard let deviceID = request.deviceID ?? host.deviceID(forWorkspaceID: request.workspaceID) else { return nil }
            let content = TerminalPanePlaceholderContentController(request: request, deviceID: deviceID)
            installContentController(content, sessionID: request.sessionID)
            scheduleTerminalPaneContentPreparation(request: request, focusIntent: focusIntent)
            return content
        }
        guard let content = host.makeTerminalPaneContent(request: request, focusIntent: focusIntent) else { return nil }
        installContentController(content, sessionID: request.sessionID)
        return content
    }

    private func installContentController(_ content: any TerminalPaneContentHosting, sessionID: String) {
        content.onTitleChanged = { [weak self, weak content] title in
            guard let self, let content, let sessionID = content.descriptor.terminalSessionID, self.placement(forSessionID: sessionID) != nil else {
                return
            }
            self.refreshTabTitles(forSessionID: sessionID)
        }
        contentControllers[sessionID] = content
    }

    private func scheduleTerminalPaneContentPreparation(request: AppKitController.DeviceTerminalOpenRequest, focusIntent: TerminalOpenFocusIntent) {
        let sessionID = request.sessionID
        guard contentPreparationTasks[sessionID] == nil else { return }
        // This Task can outlive the moment it was scheduled: it suspends on the await below and may
        // resume much later. `host` is `unowned` on the coordinator, which is only safe to read while
        // something else is guaranteed to keep the host alive; a suspended Task is not that guarantee.
        // Capturing `host` strongly here evaluates the capture synchronously at Task creation, while the
        // host is certainly alive, so the Task pins its own strong reference for its whole lifetime
        // instead of re-reading the unowned property after resuming. That creates a temporary retain
        // cycle (host -> coordinator -> task -> host), which is fine: it breaks once the Task finishes.
        // In the running app the host lives for the process anyway, so this changes nothing there; it
        // matters in test processes, where one test's host can deallocate while another test's Task
        // (sharing the process) is still suspended on this await.
        contentPreparationTasks[sessionID] = Task { @MainActor [weak self, host] in
            guard let self else { return }
            defer { self.contentPreparationTasks[sessionID] = nil }
            let result = await host.prepareTerminalPaneOpenRequest(request)
            guard !Task.isCancelled else { return }
            guard self.placement(forSessionID: sessionID) != nil else { return }
            guard self.contentControllers[sessionID] is TerminalPanePlaceholderContentController else { return }
            switch result {
            case .success(let preparedRequest):
                guard let content = host.makeTerminalPaneContent(request: preparedRequest, focusIntent: focusIntent) else {
                    (self.contentControllers[sessionID] as? TerminalPanePlaceholderContentController)?.fail(message: "Terminal pane failed to open.")
                    return
                }
                self.replacePreparingContent(content, sessionID: sessionID, focusIntent: focusIntent)
            case .failure(let error):
                // The pane itself is the report: `fail` turns it into a "Terminal unavailable" pane
                // carrying the message, which is the app's existing in-place error surface and is where a
                // user goes looking when a background launch did not come up. The modal on top of it is
                // for an open the user is waiting on; raising one for a launch a script triggered would
                // interrupt whatever they were doing to announce a pane they never asked to see.
                (self.contentControllers[sessionID] as? TerminalPanePlaceholderContentController)?.fail(error: error)
                host.reportTerminalPaneOpenFailure(error, focusIntent: focusIntent)
            }
        }
    }

    /// Swaps a ready terminal in for its placeholder. Ownership is reclaimed if the open asked for it,
    /// and the pane runs if it is visible, both regardless of focus intent: only the caret is withheld.
    private func replacePreparingContent(_ content: TerminalPaneContentController, sessionID: String, focusIntent: TerminalOpenFocusIntent) {
        guard let previous = contentControllers[sessionID] as? TerminalPanePlaceholderContentController else { return }
        let requestsOwnership = previous.requestsOwnershipWhenReady
        // Read before the swap: replacing the placeholder tears its view out, taking the first responder
        // with it, so afterwards there is no way to tell whether the user had clicked into this pane.
        let previousHeldKeyboardFocus = NSApp.keyWindow?.firstResponder.map { previous.owns(responder: $0) } ?? false
        installContentController(content, sessionID: sessionID)
        if requestsOwnership { content.requestOwnershipIfNeeded() }
        previous.close()
        guard let placement = placement(forSessionID: sessionID) else { return }
        render(scope: placement.scope)
        if let pane = PanelLayoutEngine.pane(withID: placement.paneID, in: layout(for: placement.scope)) {
            activateContentIfVisible(scope: placement.scope, pane: pane)
        }
        switch AppKitController.terminalPanePreparationFocusAction(
            focusIntent: focusIntent, preparedPaneHoldsKeyboardFocus: previousHeldKeyboardFocus)
        {
        case .none: return
        case .restoreToPreparedPane: _ = content.makeContentFirstResponder()
        case .activatePanelFocusedPane: activateFocusedPane(scope: placement.scope)
        }
    }

    /// Recomputes every tab's title for a visible panel in place (the lightweight
    /// per-tab path, which preserves an in-progress rename editor). The workspace-detail
    /// fast path calls this on overview ticks: those can rename runtime targets without
    /// mutating the layout, so nothing else would re-derive the tab strip titles.
    func refreshTabTitles(scope: PanelScope) {
        withRuntimeTargetTitlePass {
            guard let state = panels[scope], let view = state.view else { return }
            for tab in state.layout.tabs { view.updateTabTitle(tabTitle(forTabID: tab.id, in: state.layout), forTabID: tab.id) }
            syncPaneAccessibilityTitles(scope: scope)
            syncPanelWindowTitle(scope: scope)
            syncFocusedPaneFooter(scope: scope)
        }
    }

    /// Re-titles every materialized global panel window after an overview update.
    ///
    /// A rename (and its clearing) reaches this client only through the overview — nothing emits a
    /// pane or metadata event for it — and only the visible workspace panel is re-titled on an
    /// overview tick. A global panel window would otherwise keep the name it last derived until some
    /// unrelated pane event happened to re-title it. One shared title pass covers every scope, so the
    /// runtime-target lookup is built once per workspace rather than once per panel; a client with no
    /// global panel open — the common case, and this runs on every sidebar rebuild — opens no pass at
    /// all.
    func refreshGlobalPanelTitles() {
        let panelWindowIDs = Self.globalPanelWindowIDsNeedingOverviewTitleRefresh(panels.keys)
        guard !panelWindowIDs.isEmpty else { return }
        withRuntimeTargetTitlePass { for panelWindowID in panelWindowIDs { refreshTabTitles(scope: .globalWindow(panelWindowID: panelWindowID)) } }
    }

    /// Which of the coordinator's panel scopes an overview update has to re-title: the global panel
    /// windows, in id order.
    ///
    /// Workspace scopes are deliberately excluded — the workspace-detail path already re-titles the
    /// visible one in place on every overview tick, and one that is not visible is re-rendered (and so
    /// re-titled) when it becomes visible. A global panel window has neither: it stands in its own
    /// window that no overview update re-renders.
    nonisolated static func globalPanelWindowIDsNeedingOverviewTitleRefresh(_ scopes: some Collection<PanelScope>) -> [String] {
        scopes.compactMap { scope in
            guard case .globalWindow(let panelWindowID) = scope else { return nil }
            return panelWindowID
        }.sorted()
    }

    private func refreshTabTitles(forSessionID sessionID: String?) {
        withRuntimeTargetTitlePass {
            guard let sessionID, let placement = placement(forSessionID: sessionID), let view = panels[placement.scope]?.view else { return }
            view.updateTabTitle(tabTitle(forTabID: placement.tabID, in: layout(for: placement.scope)), forTabID: placement.tabID)
            syncPaneAccessibilityTitles(scope: placement.scope)
            syncPanelWindowTitle(scope: placement.scope)
            syncFocusedPaneFooter(scope: placement.scope)
        }
    }

    /// Publishes each pane's resolved title onto its content view's accessibility label
    /// (see `TerminalPaneContentController.setAccessibilityRuntimeTargetName`). Every
    /// render/title-refresh path calls this so the front window's selected-tab session
    /// stays identifiable by name to UI automation and VoiceOver — the shared window
    /// title no longer distinguishes panes post-panel-rework.
    private func syncPaneAccessibilityTitles(scope: PanelScope) {
        guard let layout = panels[scope]?.layout else { return }
        for sessionID in PanelLayoutEngine.orderedTerminalSessionIDs(in: layout) {
            contentControllers[sessionID]?.setAccessibilityRuntimeTargetName(contentTitle(forSessionID: sessionID))
        }
    }

    /// The selected workspace footer shows the focused pane's identity; re-sync it
    /// whenever a workspace panel's layout or titles change.
    private func syncFocusedPaneFooter(scope: PanelScope) {
        guard case .workspace(_, let workspaceID) = scope else { return }
        host.refreshWorkspaceFooterFocusedPane(workspaceID: workspaceID)
    }

    /// The focused pane's identity for a workspace panel (footer display).
    func focusedPaneInfo(deviceID: String, workspaceID: String) -> (paneID: String, title: String)? {
        withRuntimeTargetTitlePass {
            let layout = layout(for: .workspace(deviceID: deviceID, workspaceID: workspaceID))
            guard let paneID = layout.focusedPaneID, let pane = PanelLayoutEngine.pane(withID: paneID, in: layout) else { return nil }
            return (paneID, contentTitle(for: pane))
        }
    }

    /// Closes a panel's focused pane (the ⌘W behavior — the last pane of a tab takes
    /// the tab with it, and a global window's last tab closes the window).
    @discardableResult func closeFocusedPane(scope: PanelScope) -> Bool {
        let layout = layout(for: scope)
        guard let paneID = layout.focusedPaneID, PanelLayoutEngine.pane(withID: paneID, in: layout) != nil else { return false }
        closePane(scope: scope, paneID: paneID)
        return true
    }

    /// A tab is titled after its user-chosen name when set, else after its selected pane —
    /// the one the user is looking at, which in a split is the pane that last held focus
    /// here. A tab's title therefore follows the user across a split instead of being
    /// pinned to whichever pane happens to sit first in the tree.
    private func tabTitle(forTabID tabID: String, in layout: PanelLayout) -> String {
        guard let tab = layout.tabs.first(where: { $0.id == tabID }) else { return "Terminal" }
        if let custom = tab.title { return custom }
        guard let pane = PanelLayoutEngine.selectedPane(in: tab) else { return "Terminal" }
        return contentTitle(for: pane)
    }

    /// A pane's display title, terminal or code: the runtime target's name (what the sidebar row shows
    /// — e.g. "codex", "npm:dev", "shell-1") when a terminal session backs one, else its content's own
    /// display title.
    private func contentTitle(for pane: Pane) -> String {
        switch pane.content {
        case .terminalSession(_, let sessionID): return contentTitle(forSessionID: sessionID)
        case .codePane: return codePaneControllers[pane.id]?.displayTitle ?? "Code"
        }
    }

    /// A terminal pane's display title: the runtime target's name when the session backs one. What the
    /// program inside prints never renames the pane; it reads as the row's secondary text in the
    /// sidebar instead. A session no target claims — one whose workspace rows the overview no longer
    /// lists — has no name but the terminal's own.
    private func contentTitle(forSessionID sessionID: String) -> String {
        guard let content = contentControllers[sessionID] else { return "Terminal" }
        return runtimeTargetTitle(forSessionID: sessionID, workspaceID: content.workspaceID) ?? content.displayTitle
    }

    /// Runs one title pass with a shared runtime-target title lookup. Resolving a workspace's
    /// runtime-target titles rebuilds its whole ordered target list, and a single pass resolves a
    /// title for every tab, every pane's accessibility label, and the focused-pane footer — so
    /// without sharing, one pass rebuilds that list once per session in the panel. Passes nest (the
    /// footer sync re-enters through the host), and the lookup is dropped when the outermost pass
    /// ends: a pass is synchronous, so it cannot straddle an overview update and serve a stale title.
    private func withRuntimeTargetTitlePass<T>(_ body: () -> T) -> T {
        runtimeTargetTitlePassDepth += 1
        defer {
            runtimeTargetTitlePassDepth -= 1
            if runtimeTargetTitlePassDepth == 0 { runtimeTargetTitlesByWorkspaceID.removeAll() }
        }
        return body()
    }

    private func runtimeTargetTitle(forSessionID sessionID: String, workspaceID: String) -> String? {
        if let titles = runtimeTargetTitlesByWorkspaceID[workspaceID] { return titles[sessionID] }
        let titles = host.runtimeTargetTitlesBySessionID(workspaceID: workspaceID)
        // Only a pass may retain a lookup: outside one nothing would ever drop it, and the next
        // read would answer from a map built before an overview update.
        if runtimeTargetTitlePassDepth > 0 { runtimeTargetTitlesByWorkspaceID[workspaceID] = titles }
        return titles[sessionID]
    }

    // MARK: - Rendering / persistence

    /// The panel scope for a workspace, or nil when no loaded device owns it. Panel state is
    /// keyed by (deviceID, workspaceID), so guessing the device would split one workspace's
    /// panel across two keys and mint a fresh empty panel beside its real one.
    private func workspaceScope(forWorkspaceID workspaceID: String) -> PanelScope? {
        guard let deviceID = host.deviceID(forWorkspaceID: workspaceID) else { return nil }
        return .workspace(deviceID: deviceID, workspaceID: workspaceID)
    }

    private func mutateLayout(scope: PanelScope, rerender: Bool = true, _ mutation: (PanelLayout) -> PanelLayout) {
        var state = panels[scope] ?? PanelState()
        let previousVisibility = state.layout.selectedTabID
        state.layout = mutation(state.layout)
        panels[scope] = state
        if rerender { render(scope: scope) }
        if previousVisibility != state.layout.selectedTabID {
            for tab in state.layout.tabs { for pane in PanelLayoutEngine.panes(in: tab) { activateContentIfVisible(scope: scope, pane: pane) } }
        }
        onLayoutChanged?(scope, state.layout)
        // A global panel exists only while it has content: an emptied layout (last tab
        // closed or last pane moved away) closes its window shell.
        if case .globalWindow(let panelWindowID) = scope, state.layout.isEmpty { dismissPanelWindowShell(panelWindowID: panelWindowID) }
    }

    private func render(scope: PanelScope) {
        withRuntimeTargetTitlePass {
            guard let state = panels[scope], let view = state.view else { return }
            var titles: [String: String] = [:]
            for tab in state.layout.tabs { titles[tab.id] = tabTitle(forTabID: tab.id, in: state.layout) }
            view.apply(layout: state.layout, titlesByTabID: titles, newTabShortcutHint: host.footerShortcutHint(for: .guiOpenTerminalShortcut))
            syncPaneAccessibilityTitles(scope: scope)
            syncPanelWindowTitle(scope: scope)
            syncFocusedPaneFooter(scope: scope)
        }
    }
}
