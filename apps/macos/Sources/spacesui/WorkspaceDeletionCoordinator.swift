import Foundation
import spacesdevicecore
import workspacecore

/// Owns the workspace-delete marking domain: the local pending-delete set that keeps a deleting
/// workspace's sidebar row listed and inert while the daemon works through the mutation, and the
/// deferred-resolution bookkeeping for deletes whose fate reconciliation could not prove before its
/// retry budget ran out. Extracted from `AppKitController` as a behavior-preserving move (part of the
/// ongoing decomposition of that type); `AppKitController` holds this as `workspaceDeletion` and reaches
/// it as `host.workspaceDeletion` from other files (`SidebarController`) that read the pending set or its
/// derived row marking. `deleteWorkspace` itself — the mutation call, its reconciliation loop, and the
/// browser/pane cleanup on a confirmed delete — stays on `AppKitController`, routing its touches of the
/// marking and the deferred-resolution map through this type.
@MainActor final class WorkspaceDeletionCoordinator {
    unowned let host: AppKitController

    init(host: AppKitController) {
        self.host = host
    }

    /// Workspaces whose delete mutation is in flight. Deleting a workspace takes seconds on the owning
    /// daemon — it stops the workspace, then removes the git worktree — and every overview that lands in
    /// that window still lists the workspace, so removing the row up front would let the next background
    /// refresh put it back for a beat before it finally disappears. The row stays and renders marked as
    /// deleting instead (see `sidebarWorkspaceRowState`), whatever rebuilds happen meanwhile.
    /// In-memory and per-run, like `pendingNewTerminalSessionWorkspaceIDs`: a relaunch reloads from the
    /// daemons, which are authoritative about whether the delete landed.
    ///
    /// Deletes issued from this app only. What the row renders is `isWorkspaceMarkedDeleting`, which
    /// unions this with the teardowns the owning daemon reports; this set stays exactly the deletes this
    /// app has to see through, since it is what the reconciliation paths key their outcome on.
    private(set) var workspaceIDsPendingDeletion: Set<String> = []

    /// What `deleteWorkspace` held back when `WorkspaceDeletionReconciler` returned `.unknown` — every
    /// reconciliation refetch failed, so no overview ever proved the delete's fate either way. The
    /// workspace stays in `workspaceIDsPendingDeletion` (its row stays inert) and this is what
    /// `resolveAwaitingWorkspaceDeletions` needs once a real overview for `deviceID` finally arrives:
    /// which device to check, the error to surface if the workspace is still there, whether to show the
    /// branch-outcome notice if it is gone, and the browser windows/panes a confirmed-gone resolution
    /// still has to close (the same cleanup an immediate `.gone` verdict performs).
    private struct AwaitingWorkspaceDeletionResolution {
        let deviceID: String
        let error: Error
        let branchDeletionRequested: Bool
        let browserSessionTargetURLs: [String]
        /// `deviceID`'s `DeviceSection.overviewInstallGeneration` at the moment reconciliation gave up.
        /// Resolution waits for a fresh install for this exact device — one whose generation exceeds
        /// this snapshot — rather than settling on any `workspacesByProject` rebuild, which fires for
        /// every device's refresh and would otherwise reread this device's own untouched cached overview
        /// as if it were new evidence.
        let overviewInstallGenerationAtDefer: Int
    }

    /// Workspaces whose delete reconciliation exhausted its attempt budget without a single overview
    /// resolving (`WorkspaceDeletionReconciler.Outcome.unknown`). In-memory and per-run, like
    /// `workspaceIDsPendingDeletion`: a relaunch always refetches reality from the daemon instead of
    /// trusting anything held here.
    private var workspaceIDsAwaitingDeletionResolution: [String: AwaitingWorkspaceDeletionResolution] = [:]

    /// Records the outcome `deleteWorkspace` held back after its own reconciliation returned `.unknown`,
    /// keyed by workspace ID, so `resolveAwaitingWorkspaceDeletions` can settle it once a fresh overview
    /// for `deviceID` lands. `deleteWorkspace` stays on `AppKitController`, so this is the one write into
    /// `workspaceIDsAwaitingDeletionResolution` a caller outside this type needs.
    func deferResolution(
        workspaceID: String, deviceID: String, error: Error, branchDeletionRequested: Bool, browserSessionTargetURLs: [String],
        overviewInstallGenerationAtDefer: Int
    ) {
        workspaceIDsAwaitingDeletionResolution[workspaceID] = AwaitingWorkspaceDeletionResolution(
            deviceID: deviceID, error: error, branchDeletionRequested: branchDeletionRequested,
            browserSessionTargetURLs: browserSessionTargetURLs, overviewInstallGenerationAtDefer: overviewInstallGenerationAtDefer)
    }

    /// What a workspace awaiting deferred delete resolution (see `AwaitingWorkspaceDeletionResolution`)
    /// should do once `resolveAwaitingWorkspaceDeletions` finds a candidate overview for its device.
    enum AwaitingWorkspaceDeletionResolutionVerdict: Equatable {
        /// No overview for the owning device is installed yet (it is nil — offline, not yet loaded, or a
        /// wire-incompatible placeholder). Nothing was proved either way, so the entry keeps waiting.
        case stillAwaiting
        /// An overview resolved and did not list the workspace: the delete landed. Clear the marking
        /// silently; `showsBranchOutcomeNotice` says whether the caller also has to surface the notice
        /// that branch deletion's own result was lost.
        case gone(showsBranchOutcomeNotice: Bool)
        /// An overview resolved and still lists the workspace: the held-back error is real and has to be
        /// surfaced now.
        case present
    }

    /// The pure decision `resolveAwaitingWorkspaceDeletions` makes per entry, factored out so it is
    /// testable without a live `AppKitController` — mirroring `WorkspaceDeletionReconciler`, an I/O-free
    /// type driven by an injected overview rather than a live device connection. `overview` is whatever
    /// `deviceSections` currently has installed for the workspace's owning device — `nil` until that
    /// device's next overview install actually lands.
    ///
    /// `overviewInstallGeneration` and `overviewInstallGenerationAtDefer` gate the verdict on *fresh*
    /// evidence for the owning device: `resolveAwaitingWorkspaceDeletions` is hooked off a
    /// `workspacesByProject` rebuild that fires for every device's refresh, not just the owning device's,
    /// and an offline owning device keeps its last-known (pre-delete) overview rather than clearing it.
    /// Without this check, some other device's refresh would trigger a rebuild that rereads the owning
    /// device's untouched cached overview, sees the workspace still listed, and wrongly concludes
    /// `.present` — a verdict drawn from evidence that predates the delete. Requiring the generation to
    /// have advanced past its captured-at-defer snapshot means the verdict is only drawn once this
    /// specific device's overview has actually been reinstalled since the defer.
    nonisolated static func resolveAwaitingWorkspaceDeletion(
        overview: SpacesDeviceOverviewPayload?, overviewInstallGeneration: Int, overviewInstallGenerationAtDefer: Int, workspaceID: String,
        branchDeletionRequested: Bool
    ) -> AwaitingWorkspaceDeletionResolutionVerdict {
        guard let overview, overviewInstallGeneration > overviewInstallGenerationAtDefer else { return .stillAwaiting }
        guard overview.workspaces.contains(where: { $0.id == workspaceID }) else { return .gone(showsBranchOutcomeNotice: branchDeletionRequested) }
        // Listed, but the daemon reports it is still tearing this workspace down: that is not the delete
        // having failed, it is the delete still running. Keep waiting rather than telling the user a
        // workspace survived that the daemon is about to remove.
        return overview.workspaceIDsWithTeardownInFlight.contains(workspaceID) ? .stillAwaiting : .present
    }

    /// Marks a workspace whose delete the user just confirmed, and moves the selection off it: a marked
    /// row is inert, so it must not stay selected with its detail pane open. The marking is read on every
    /// row build, so overview refreshes that land while the daemon works through the delete keep showing
    /// the row as deleting instead of restoring it to normal.
    func beginPendingWorkspaceDeletion(workspaceID: String, projectID: String) {
        workspaceIDsPendingDeletion.insert(workspaceID)
        if host.selectedWorkspaceID == workspaceID {
            host.selectedWorkspaceID = nil
            host.selectedProjectID = projectID
        }
        applyPendingWorkspaceDeletionMarking()
    }

    /// Clears the marking once the delete resolves. After a successful delete the workspace is already
    /// gone from the refreshed overview, so the row leaves once; after a failed one the row returns to
    /// normal, with the user's expansion state intact because marking never touched it.
    func endPendingWorkspaceDeletion(workspaceID: String) {
        guard workspaceIDsPendingDeletion.remove(workspaceID) != nil else { return }
        applyPendingWorkspaceDeletionMarking()
    }

    /// Rebuilds the rows against the current marking. The sidebar data itself is unchanged — a workspace
    /// being deleted keeps its row — so only the row views and the expansion state (a marked row hides
    /// its runtime targets) have to be reapplied.
    private func applyPendingWorkspaceDeletionMarking() {
        host.fullReloadSidebarOutline()
        host.refreshSelection()
    }

    /// Resolves every entry in `workspaceIDsAwaitingDeletionResolution` whose owning device now has an
    /// overview installed. Hooked off the `workspacesByProject` `didSet` (see its comment) because that
    /// is the nearest point in this file every overview-install path — the local snapshot, a remote
    /// pull/subscription, and a mutation response, including `deleteWorkspace`'s own reconciliation
    /// refetches — is guaranteed to reach, without requiring `SidebarController` to know this feature
    /// exists.
    ///
    /// Each entry is independent: an overview that resolves one device's workspace says nothing about
    /// another device's, and a device whose current overview is `nil` — offline, not yet loaded, or the
    /// empty placeholder a wire-incompatible daemon answers with — has proved nothing either way, so
    /// that entry is left waiting for a later install with real data.
    ///
    /// This `didSet` fires for a rebuild triggered by *any* device's refresh, not just the owning
    /// device's, so an overview alone is not enough evidence: an offline owning device keeps its
    /// last-known (pre-delete) overview rather than clearing it, and reading that stale snapshot on a
    /// rebuild some other device caused would draw a verdict that predates the delete. Each entry also
    /// captures the owning device's `overviewInstallGeneration` at defer time and only resolves once
    /// that device's own generation has advanced past it — i.e. once this specific device has actually
    /// reinstalled an overview since the defer, not merely been read again.
    func resolveAwaitingWorkspaceDeletions() {
        guard !workspaceIDsAwaitingDeletionResolution.isEmpty else { return }
        for (workspaceID, pending) in workspaceIDsAwaitingDeletionResolution {
            // A missing section (device unpaired mid-defer) falls back to comparing the captured
            // generation against itself, i.e. `.stillAwaiting` — there is no fresher evidence to read.
            let section = host.deviceModel.deviceSections.first(where: { $0.deviceID == pending.deviceID })
            switch Self.resolveAwaitingWorkspaceDeletion(
                overview: section?.overview,
                overviewInstallGeneration: section?.overviewInstallGeneration ?? pending.overviewInstallGenerationAtDefer,
                overviewInstallGenerationAtDefer: pending.overviewInstallGenerationAtDefer, workspaceID: workspaceID,
                branchDeletionRequested: pending.branchDeletionRequested)
            {
            case .stillAwaiting: continue
            case .present:
                workspaceIDsAwaitingDeletionResolution.removeValue(forKey: workspaceID)
                endPendingWorkspaceDeletion(workspaceID: workspaceID)
                host.requestSidebarReload()
                host.showError(pending.error)
            case .gone(let showsBranchOutcomeNotice):
                workspaceIDsAwaitingDeletionResolution.removeValue(forKey: workspaceID)
                endPendingWorkspaceDeletion(workspaceID: workspaceID)
                // Same client cleanup an immediate `.gone` verdict performs in `deleteWorkspace` —
                // otherwise a deferred-but-confirmed delete would leave this workspace's browser windows
                // and terminal panes open indefinitely.
                host.browserSessions.closeLocalBrowserSessionWindows(
                    workspaceID: workspaceID, configuredBrowserSessionTargetURLs: pending.browserSessionTargetURLs)
                host.closeWorkspacePanes(workspaceID: workspaceID)
                if showsBranchOutcomeNotice {
                    host.showInfoMessage(title: "Deleted workspace", message: AppKitController.workspaceDeletionBranchOutcomeUnknownMessage)
                }
            }
        }
    }
}
