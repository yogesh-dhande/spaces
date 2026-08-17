import Foundation
import Testing
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import workspacecore

@testable import spacesui

/// Deleting a workspace runs for seconds on the owning daemon (it stops the workspace, then removes the
/// git worktree), and every overview that lands in that window still reports the workspace. These cover
/// the contract that makes that window readable: the row stays listed and renders marked as deleting —
/// dimmed, spinning, children hidden, inert — and it leaves the sidebar exactly once, when the
/// post-delete overview stops carrying it.
@Suite struct AppKitControllerPendingWorkspaceDeletionTests {
    @Test func aWorkspacePendingDeletionKeepsItsRowAndRendersMarked() {
        // The daemon still reports the workspace mid-delete, so a refresh landing during the mutation
        // rebuilds from a section that contains it — and it keeps its row rather than disappearing and
        // coming back on the next refresh. The row carries the delete instead: dimmed, with a progress
        // indicator, its runtime targets hidden whatever the user had expanded, and refusing selection,
        // its context menu, and expansion.
        let merged = AppKitController.mergedSidebarData(sections: [deviceSection()])
        #expect(merged.workspacesByProject["proj"]?.map(\.id) == ["ws-deleting", "ws-keep"])
        #expect(merged.workspaceRuntimeStatusByID["ws-deleting"] != nil)
        #expect(merged.alertsGroups.map(\.workspaceID) == ["ws-deleting", "ws-keep"])

        let marked = AppKitController.sidebarWorkspaceRowState(isPendingDeletion: true)
        #expect(marked.alpha == AppKitController.unreachableDeviceAlpha)
        #expect(marked.showsDeletingProgress)
        #expect(!marked.listsRuntimeTargetChildren)
        #expect(!marked.isInteractive)
    }

    @Test func aWorkspaceThatIsNotBeingDeletedRendersNormally() {
        // Every other row is untouched by the marking: full opacity, no spinner, its runtime targets
        // listed as children, and fully interactive.
        let normal = AppKitController.sidebarWorkspaceRowState(isPendingDeletion: false)
        #expect(normal.alpha == 1)
        #expect(!normal.showsDeletingProgress)
        #expect(normal.listsRuntimeTargetChildren)
        #expect(normal.isInteractive)
    }

    @Test func aFailedDeleteRestoresTheNormalRow() {
        // Walk the marking the way the delete does: marked on confirm, cleared when the mutation comes
        // back. A failure leaves the workspace exactly where it was in the sidebar data, and its row
        // returns to the normal treatment — children listed again, since the marking never touched the
        // user's expansion state.
        var pendingDeletion: Set<String> = ["ws-deleting"]
        #expect(!AppKitController.sidebarWorkspaceRowState(isPendingDeletion: pendingDeletion.contains("ws-deleting")).isInteractive)

        pendingDeletion.remove("ws-deleting")
        let restored = AppKitController.sidebarWorkspaceRowState(isPendingDeletion: pendingDeletion.contains("ws-deleting"))
        #expect(restored == AppKitController.sidebarWorkspaceRowState(isPendingDeletion: false))

        let merged = AppKitController.mergedSidebarData(sections: [deviceSection()])
        #expect(merged.workspacesByProject["proj"]?.map(\.id) == ["ws-deleting", "ws-keep"])
        #expect(merged.workspaceRuntimeStatusByID["ws-deleting"] != nil)
    }

    @Test func aCompletedDeleteDropsTheRowOnce() {
        // The post-delete overview no longer carries the workspace, so once the marking is cleared the
        // row is simply gone — it does not come back, and nothing else under the project moves.
        var section = deviceSection()
        section.workspacesByProject["proj"]?.removeAll { $0.id == "ws-deleting" }
        section.workspaceRuntimeStatusByID["ws-deleting"] = nil
        section.alertsGroups.removeAll { $0.workspaceID == "ws-deleting" }

        let merged = AppKitController.mergedSidebarData(sections: [section])

        #expect(merged.workspacesByProject["proj"]?.map(\.id) == ["ws-keep"])
        #expect(merged.workspaceRuntimeStatusByID["ws-deleting"] == nil)
        #expect(merged.alertsGroups.map(\.workspaceID) == ["ws-keep"])
        #expect(merged.projects.map(\.id) == ["proj"])
    }

    /// A delete does not have to have been issued from this Mac to mark a row. The owning daemon reports
    /// every teardown it is running, so a workspace deleted from the iPhone — or taken by a project
    /// delete — renders marked here too, with nothing in this app's own pending set, and goes back to an
    /// ordinary row once its device's overview stops reporting the teardown.
    @Test func aWorkspaceTheDaemonReportsTearingDownIsMarkedWithNoLocalDelete() {
        let tearingDown = SpacesDeviceOverviewPayload(
            workspaces: [deviceWorkspaceSummary(id: "ws-deleting"), deviceWorkspaceSummary(id: "ws-keep")], sessions: [],
            workspaceIDsWithTeardownInFlight: ["ws-deleting"])

        #expect(AppKitController.isWorkspaceMarkedDeleting(workspaceID: "ws-deleting", pendingDeletionWorkspaceIDs: [], deviceOverview: tearingDown))
        #expect(!AppKitController.isWorkspaceMarkedDeleting(workspaceID: "ws-keep", pendingDeletionWorkspaceIDs: [], deviceOverview: tearingDown))

        let settled = SpacesDeviceOverviewPayload(workspaces: [deviceWorkspaceSummary(id: "ws-deleting")], sessions: [])
        #expect(!AppKitController.isWorkspaceMarkedDeleting(workspaceID: "ws-deleting", pendingDeletionWorkspaceIDs: [], deviceOverview: settled))

        // A device with no overview installed (offline, not yet loaded) still marks this app's own deletes.
        #expect(
            AppKitController.isWorkspaceMarkedDeleting(workspaceID: "ws-deleting", pendingDeletionWorkspaceIDs: ["ws-deleting"], deviceOverview: nil))
        #expect(!AppKitController.isWorkspaceMarkedDeleting(workspaceID: "ws-deleting", pendingDeletionWorkspaceIDs: [], deviceOverview: nil))
    }

    /// A non-git project owns one workspace and gives it no row of its own: the project row stands in for
    /// it. That row therefore has to render and respond to the workspace's marked state — a project delete
    /// reported by another client would otherwise leave its menu, selection, expansion and click intact
    /// while the worktree is being removed. A git project's row stands in for no workspace, so nothing
    /// marks it; the workspace rows beneath it carry their own marks.
    @Test func aNonGitProjectStandInRowTakesItsWorkspacesMarkedState() {
        let marked = AppKitController.sidebarProjectRowState(standInWorkspaceIsPendingDeletion: true)
        #expect(marked == AppKitController.sidebarWorkspaceRowState(isPendingDeletion: true))
        #expect(marked.alpha == AppKitController.unreachableDeviceAlpha)
        #expect(marked.showsDeletingProgress)
        #expect(!marked.listsRuntimeTargetChildren)
        #expect(!marked.isInteractive)

        let normal = AppKitController.sidebarWorkspaceRowState(isPendingDeletion: false)
        #expect(AppKitController.sidebarProjectRowState(standInWorkspaceIsPendingDeletion: false) == normal)
        #expect(AppKitController.sidebarProjectRowState(standInWorkspaceIsPendingDeletion: nil) == normal)
    }

    private func deviceWorkspaceSummary(id: String) -> SpacesDeviceWorkspaceSummary {
        SpacesDeviceWorkspaceSummary(
            id: id, projectID: "proj", projectName: "Project", branch: id, baseBranch: "main", dir: "/project-\(id)", isRunning: false,
            isHidden: false, isDefault: false, sessionCount: 0)
    }

    /// One project with the workspace being deleted and a sibling that must survive, plus the runtime
    /// state and alerts group each of them owns.
    private func deviceSection() -> AppKitController.DeviceSection {
        AppKitController.DeviceSection(
            deviceID: "local", deviceName: "local", isLocal: true, loadState: .loaded, device: nil,
            projects: [ProjectSummary(id: "proj", name: "Project", dir: "/project", isGitRepo: true, defaultBranch: "main", deviceID: "local")],
            workspacesByProject: [
                "proj": [
                    WorkspaceSummary(
                        id: "ws-deleting", branch: "doomed", dir: "/project-doomed", isRunning: true, isDefault: false, deviceID: "local"),
                    WorkspaceSummary(id: "ws-keep", branch: "keep", dir: "/project-keep", isRunning: true, isDefault: false, deviceID: "local"),
                ]
            ],
            workspaceRuntimeStatusByID: ["ws-deleting": runtimeStatus(workspaceID: "ws-deleting"), "ws-keep": runtimeStatus(workspaceID: "ws-keep")],
            alertsGroups: [
                AppKitController.AlertsGroup(
                    projectName: "Project", workspaceID: "ws-deleting", workspaceName: "doomed", workspaceBranch: "doomed",
                    isFromHiddenWorkspace: false, items: []),
                AppKitController.AlertsGroup(
                    projectName: "Project", workspaceID: "ws-keep", workspaceName: "keep", workspaceBranch: "keep", isFromHiddenWorkspace: false,
                    items: []),
            ])
    }

    private func runtimeStatus(workspaceID: String) -> WorkspaceRuntimeStatus {
        WorkspaceRuntimeStatus(
            workspaceID: workspaceID, lifecycleState: .running, runtimeHealth: .healthy, hasTrackedRuntimeIndicators: false, runningProcessCount: 1,
            exitedProcessCount: 0, waitingAgentWindowCount: 0, missingConfiguredProcessCount: 0, missingConfiguredBrowserSessionCount: 0)
    }
}

/// The daemon runs a delete's teardown on its own queue, well past what `deleteWorkspace`'s own
/// request timeout allows, so a failed delete is only a definitive rejection when the daemon actually
/// answered it — everything else has to be reconciled against fresh overviews instead of reported
/// outright (see `AppKitController.isIndeterminateDeleteOutcome` and `WorkspaceDeletionReconciler`).
/// `AppKitController` itself needs a live AppKit window to construct, so these cover the two testable
/// seams `deleteWorkspace` is built from directly: the classification and the reconciliation loop.
@Suite @MainActor struct WorkspaceDeletionReconciliationTests {
    /// A daemon-coded rejection is the one shape that proves the daemon answered — every other error
    /// this request can throw carries no code, coded or not, and must reconcile instead.
    @Test func onlyADaemonCodedRejectionIsDefinitive() {
        #expect(!AppKitController.isIndeterminateDeleteOutcome(SpacesDeviceClientError.requestRejected(message: "nope", code: .notFound)))
        #expect(!AppKitController.isIndeterminateDeleteOutcome(SpacesDeviceClientError.requestRejected(message: "nope", code: .invalidArgument)))
        #expect(!AppKitController.isIndeterminateDeleteOutcome(SpacesDeviceClientError.requestRejected(message: "nope", code: .unauthorized)))
        #expect(AppKitController.isIndeterminateDeleteOutcome(SpacesDeviceClientError.unavailable("request timed out")))
        #expect(AppKitController.isIndeterminateDeleteOutcome(SpacesDeviceClientError.missingOverview))
        #expect(AppKitController.isIndeterminateDeleteOutcome(NSError(domain: "test", code: 1)))
    }

    /// The daemon answers with a coded `internalError` both for a failure part-way through the delete and
    /// for a delete that SUCCEEDED and then failed while building the refreshed overview it answers with.
    /// Reading that as a refusal would restore a row for a workspace that is already gone, so it has to
    /// reconcile like any other outcome the client cannot vouch for.
    @Test func aCodedInternalErrorIsNotAVerdictAndReconciles() {
        #expect(AppKitController.isIndeterminateDeleteOutcome(SpacesDeviceClientError.requestRejected(message: "boom", code: .internalError)))
        #expect(!SpacesDeviceErrorCode.internalError.isRequestVerdict)
        #expect(SpacesDeviceErrorCode.invalidArgument.isRequestVerdict)
    }

    /// Reconciliation stops the moment a refetched overview no longer lists the workspace, instead of
    /// spending the rest of its budget: the delete is confirmed complete and the caller is not made to
    /// wait out attempts that can no longer change the answer. Every overview that did resolve — just
    /// the one here — is still handed to `applyOverview`, exactly as an ordinary refresh would apply it.
    @Test func reconciliationStopsAsSoonAsTheWorkspaceIsConfirmedGone() async {
        let reconciler = WorkspaceDeletionReconciler()
        reconciler.interval = .zero
        var fetchCount = 0
        var appliedOverviews: [SpacesDeviceOverviewPayload] = []

        let outcome = await reconciler.reconcile(
            workspaceID: "ws-deleting",
            fetchOverview: {
                fetchCount += 1
                return SpacesDeviceOverviewPayload(workspaces: [workspaceSummary(id: "ws-keep")], sessions: [])
            }, applyOverview: { appliedOverviews.append($0) })

        #expect(outcome == .gone)
        #expect(fetchCount == 1)
        #expect(appliedOverviews.count == 1)
    }

    /// A workspace that is still listed on every refetch exhausts the whole attempt budget rather than
    /// resolving early, and is reported present so the caller restores the row and surfaces the
    /// original error.
    @Test func reconciliationExhaustsItsBudgetWhenTheWorkspaceOutlivesIt() async {
        let reconciler = WorkspaceDeletionReconciler()
        reconciler.interval = .zero
        var fetchCount = 0

        let outcome = await reconciler.reconcile(
            workspaceID: "ws-deleting",
            fetchOverview: {
                fetchCount += 1
                return SpacesDeviceOverviewPayload(workspaces: [workspaceSummary(id: "ws-deleting")], sessions: [])
            }, applyOverview: { _ in })

        #expect(outcome == .present)
        #expect(fetchCount == WorkspaceDeletionReconciler.attempts)
    }

    /// A refetch that fails outright (the transport is still down) is inconclusive rather than
    /// evidence either way — the loop keeps its budget and tries again on the next attempt instead of
    /// treating the failure as proof the workspace is gone or giving up early.
    @Test func aFailedRefetchIsRetriedRatherThanTreatedAsResolved() async {
        let reconciler = WorkspaceDeletionReconciler()
        reconciler.interval = .zero
        var fetchCount = 0

        let outcome = await reconciler.reconcile(
            workspaceID: "ws-deleting",
            fetchOverview: {
                fetchCount += 1
                return fetchCount < WorkspaceDeletionReconciler.attempts ? nil : SpacesDeviceOverviewPayload(workspaces: [], sessions: [])
            }, applyOverview: { _ in })

        #expect(outcome == .gone)
        #expect(fetchCount == WorkspaceDeletionReconciler.attempts)
    }

    /// The defect this whole three-valued `Outcome` exists to fix: every single reconciliation attempt
    /// failing outright (the device stayed unreachable for the whole budget, e.g. the Mac was asleep or
    /// the network dropped right as the delete was in flight) must NOT be reported as `.present` —
    /// nothing ever proved the workspace was still there. `AppKitController.deleteWorkspace` reads
    /// `.unknown` as "keep waiting," not "restore the row and show an error."
    @Test func everyFetchFailingIsUnknownNotPresent() async {
        let reconciler = WorkspaceDeletionReconciler()
        reconciler.interval = .zero
        var fetchCount = 0

        let outcome = await reconciler.reconcile(
            workspaceID: "ws-deleting",
            fetchOverview: {
                fetchCount += 1
                return nil
            }, applyOverview: { _ in })

        #expect(outcome == .unknown)
        #expect(fetchCount == WorkspaceDeletionReconciler.attempts)
    }

    /// The pure decision `resolveAwaitingWorkspaceDeletions` makes once a real overview lands for a
    /// workspace deferred to `.unknown`. No overview yet (the owning device hasn't installed one since
    /// the deferral — offline, not yet loaded, or the empty wire-incompatible placeholder) proves
    /// nothing, so the entry keeps waiting rather than resolving on absence-of-evidence. Generation is
    /// unmoved here (0 == 0), matching "nothing has installed since the defer."
    @Test func noOverviewYetLeavesTheEntryAwaiting() {
        let verdict = AppKitController.resolveAwaitingWorkspaceDeletion(
            overview: nil, overviewInstallGeneration: 0, overviewInstallGenerationAtDefer: 0, workspaceID: "ws-deleting",
            branchDeletionRequested: false)
        #expect(verdict == .stillAwaiting)
    }

    /// An installed overview that still lists the workspace resolves the entry to `.present`: the held-
    /// back error was real all along. Generation has advanced past its defer-time snapshot (1 > 0),
    /// i.e. this is a fresh install for the owning device, not a stale rebuild rereading old data.
    @Test func anOverviewThatStillListsTheWorkspaceResolvesToPresent() {
        let overview = SpacesDeviceOverviewPayload(workspaces: [workspaceSummary(id: "ws-deleting")], sessions: [])
        let verdict = AppKitController.resolveAwaitingWorkspaceDeletion(
            overview: overview, overviewInstallGeneration: 1, overviewInstallGenerationAtDefer: 0, workspaceID: "ws-deleting",
            branchDeletionRequested: false)
        #expect(verdict == .present)
    }

    /// An installed overview that no longer lists the workspace resolves to `.gone` — silently unless
    /// branch deletion was requested, in which case the caller still owes the unknown-branch-outcome
    /// notice (reconciliation/deferred resolution can prove the workspace is gone, not what happened to
    /// a branch the user explicitly asked to delete). Generation has advanced (1 > 0), so this is a
    /// fresh install too.
    @Test func anOverviewWithoutTheWorkspaceResolvesToGoneAndCarriesTheBranchNoticeFlag() {
        let overview = SpacesDeviceOverviewPayload(workspaces: [workspaceSummary(id: "ws-keep")], sessions: [])
        #expect(
            AppKitController.resolveAwaitingWorkspaceDeletion(
                overview: overview, overviewInstallGeneration: 1, overviewInstallGenerationAtDefer: 0, workspaceID: "ws-deleting",
                branchDeletionRequested: false) == .gone(showsBranchOutcomeNotice: false))
        #expect(
            AppKitController.resolveAwaitingWorkspaceDeletion(
                overview: overview, overviewInstallGeneration: 1, overviewInstallGenerationAtDefer: 0, workspaceID: "ws-deleting",
                branchDeletionRequested: true) == .gone(showsBranchOutcomeNotice: true))
    }

    /// The defect this generation gate exists to fix: `resolveAwaitingWorkspaceDeletions` is hooked off a
    /// `workspacesByProject` rebuild that fires for *any* device's refresh, not just the owning device's,
    /// and an offline owning device keeps its last-known (pre-delete) overview rather than clearing it.
    /// A rebuild triggered by some other device must not settle the deferral by reading that untouched,
    /// stale overview — even though it still lists the workspace, which without the generation gate would
    /// read as damning `.present` evidence. Generation is unmoved (0 == 0), so nothing new has actually
    /// been installed for this device since the defer, and the verdict must stay `.stillAwaiting`.
    /// The local device's section is rebuilt and assigned whole on every ordinary refresh, which bypasses
    /// `overview`'s `didSet`. Without carrying the counter over, the local generation would reset to zero
    /// each time and a deferred local delete could never observe fresh evidence. Carrying it over must also
    /// not manufacture evidence: re-installing the same (retained, stale) overview is not a new install.
    @Test func rebuildingASectionWholeCarriesItsInstallGenerationAndCountsEveryFreshInstall() {
        let overview = SpacesDeviceOverviewPayload(workspaces: [workspaceSummary(id: "ws-deleting")], sessions: [])
        var previous = AppKitController.DeviceSection(deviceID: "local", deviceName: "Local", isLocal: true, loadState: .loaded)
        previous.overview = overview
        let generationAfterFirstInstall = previous.overviewInstallGeneration

        // An outage rebuild re-renders the retained overview without the daemon answering: not an install.
        let retainedRebuild = AppKitController.DeviceSection(
            deviceID: "local", deviceName: "Local", isLocal: true, loadState: .loaded, overview: overview
        ).adoptingOverviewInstallGeneration(from: previous, carriesFreshInstall: false)
        #expect(retainedRebuild.overviewInstallGeneration == generationAfterFirstInstall)

        // A fresh fetch that happens to be byte-identical to the cached payload IS evidence — it is what a
        // delete that never reached the daemon looks like — so it counts.
        let identicalFreshRebuild = AppKitController.DeviceSection(
            deviceID: "local", deviceName: "Local", isLocal: true, loadState: .loaded, overview: overview
        ).adoptingOverviewInstallGeneration(from: previous, carriesFreshInstall: true)
        #expect(identicalFreshRebuild.overviewInstallGeneration == generationAfterFirstInstall + 1)

        // And that is what lets the deferred delete settle instead of staying inert for the rest of the run.
        #expect(
            AppKitController.resolveAwaitingWorkspaceDeletion(
                overview: retainedRebuild.overview, overviewInstallGeneration: retainedRebuild.overviewInstallGeneration,
                overviewInstallGenerationAtDefer: generationAfterFirstInstall, workspaceID: "ws-deleting", branchDeletionRequested: false)
                == .stillAwaiting)
        #expect(
            AppKitController.resolveAwaitingWorkspaceDeletion(
                overview: identicalFreshRebuild.overview, overviewInstallGeneration: identicalFreshRebuild.overviewInstallGeneration,
                overviewInstallGenerationAtDefer: generationAfterFirstInstall, workspaceID: "ws-deleting", branchDeletionRequested: false) == .present
        )
    }

    /// A workspace the daemon reports it is still tearing down is not evidence the delete failed, however
    /// many probes see it listed — a slow user stop script outlives the whole budget. Settling "present"
    /// there would tell the user a workspace survived that the daemon removes moments later.
    @Test func aWorkspaceStillTearingDownIsNeverEvidenceOfAFailedDelete() async {
        let reconciler = WorkspaceDeletionReconciler()
        reconciler.interval = .zero
        let tearingDown = SpacesDeviceOverviewPayload(
            workspaces: [workspaceSummary(id: "ws-deleting")], sessions: [], workspaceIDsWithTeardownInFlight: ["ws-deleting"])

        let outcome = await reconciler.reconcile(workspaceID: "ws-deleting", fetchOverview: { tearingDown }, applyOverview: { _ in })

        #expect(outcome == .unknown, "still deleting is unknown, not failed")
    }

    /// The same fact drives the deferred settle path: an entry must not resolve to `present` while the
    /// daemon still owns the teardown, and must resolve once it no longer does.
    @Test func aDeferralDoesNotSettlePresentWhileTheDaemonIsStillTearingTheWorkspaceDown() {
        let tearingDown = SpacesDeviceOverviewPayload(
            workspaces: [workspaceSummary(id: "ws-deleting")], sessions: [], workspaceIDsWithTeardownInFlight: ["ws-deleting"])
        #expect(
            AppKitController.resolveAwaitingWorkspaceDeletion(
                overview: tearingDown, overviewInstallGeneration: 2, overviewInstallGenerationAtDefer: 1, workspaceID: "ws-deleting",
                branchDeletionRequested: false) == .stillAwaiting)

        let noLongerTearingDown = SpacesDeviceOverviewPayload(workspaces: [workspaceSummary(id: "ws-deleting")], sessions: [])
        #expect(
            AppKitController.resolveAwaitingWorkspaceDeletion(
                overview: noLongerTearingDown, overviewInstallGeneration: 2, overviewInstallGenerationAtDefer: 1, workspaceID: "ws-deleting",
                branchDeletionRequested: false) == .present)
    }

    @Test func aRebuildWithNoFreshInstallForTheOwningDeviceStaysAwaitingEvenWithStaleOverviewListingIt() {
        let staleOverview = SpacesDeviceOverviewPayload(workspaces: [workspaceSummary(id: "ws-deleting")], sessions: [])
        let verdict = AppKitController.resolveAwaitingWorkspaceDeletion(
            overview: staleOverview, overviewInstallGeneration: 0, overviewInstallGenerationAtDefer: 0, workspaceID: "ws-deleting",
            branchDeletionRequested: false)
        #expect(verdict == .stillAwaiting)
    }

    /// The other side of the same gate: once the owning device's generation has actually advanced past
    /// its defer-time snapshot — a real overview reinstalled for that device, not merely reread — the
    /// deferral settles in both directions: gone (with the branch-notice flag preserved) or present.
    @Test func aFreshInstallForTheOwningDeviceSettlesTheDeferralInBothDirections() {
        let overviewWithoutWorkspace = SpacesDeviceOverviewPayload(workspaces: [workspaceSummary(id: "ws-keep")], sessions: [])
        #expect(
            AppKitController.resolveAwaitingWorkspaceDeletion(
                overview: overviewWithoutWorkspace, overviewInstallGeneration: 3, overviewInstallGenerationAtDefer: 2, workspaceID: "ws-deleting",
                branchDeletionRequested: true) == .gone(showsBranchOutcomeNotice: true))

        let overviewWithWorkspace = SpacesDeviceOverviewPayload(workspaces: [workspaceSummary(id: "ws-deleting")], sessions: [])
        #expect(
            AppKitController.resolveAwaitingWorkspaceDeletion(
                overview: overviewWithWorkspace, overviewInstallGeneration: 3, overviewInstallGenerationAtDefer: 2, workspaceID: "ws-deleting",
                branchDeletionRequested: false) == .present)
    }

    private func workspaceSummary(id: String) -> SpacesDeviceWorkspaceSummary {
        SpacesDeviceWorkspaceSummary(
            id: id, projectID: "proj", projectName: "Project", branch: "doomed", baseBranch: "main", dir: "/project-\(id)", isRunning: false,
            isHidden: false, isDefault: false, sessionCount: 0)
    }
}
