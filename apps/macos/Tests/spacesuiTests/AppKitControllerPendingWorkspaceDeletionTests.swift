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
                    projectName: "Project", workspaceID: "ws-deleting", workspaceName: "doomed", workspaceBranch: "doomed", items: []),
                AppKitController.AlertsGroup(
                    projectName: "Project", workspaceID: "ws-keep", workspaceName: "keep", workspaceBranch: "keep", items: []),
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
    /// nothing, so the entry keeps waiting rather than resolving on absence-of-evidence.
    @Test func noOverviewYetLeavesTheEntryAwaiting() {
        let verdict = AppKitController.resolveAwaitingWorkspaceDeletion(overview: nil, workspaceID: "ws-deleting", branchDeletionRequested: false)
        #expect(verdict == .stillAwaiting)
    }

    /// An installed overview that still lists the workspace resolves the entry to `.present`: the held-
    /// back error was real all along.
    @Test func anOverviewThatStillListsTheWorkspaceResolvesToPresent() {
        let overview = SpacesDeviceOverviewPayload(workspaces: [workspaceSummary(id: "ws-deleting")], sessions: [])
        let verdict = AppKitController.resolveAwaitingWorkspaceDeletion(
            overview: overview, workspaceID: "ws-deleting", branchDeletionRequested: false)
        #expect(verdict == .present)
    }

    /// An installed overview that no longer lists the workspace resolves to `.gone` — silently unless
    /// branch deletion was requested, in which case the caller still owes the unknown-branch-outcome
    /// notice (reconciliation/deferred resolution can prove the workspace is gone, not what happened to
    /// a branch the user explicitly asked to delete).
    @Test func anOverviewWithoutTheWorkspaceResolvesToGoneAndCarriesTheBranchNoticeFlag() {
        let overview = SpacesDeviceOverviewPayload(workspaces: [workspaceSummary(id: "ws-keep")], sessions: [])
        #expect(
            AppKitController.resolveAwaitingWorkspaceDeletion(overview: overview, workspaceID: "ws-deleting", branchDeletionRequested: false)
                == .gone(showsBranchOutcomeNotice: false))
        #expect(
            AppKitController.resolveAwaitingWorkspaceDeletion(overview: overview, workspaceID: "ws-deleting", branchDeletionRequested: true)
                == .gone(showsBranchOutcomeNotice: true))
    }

    private func workspaceSummary(id: String) -> SpacesDeviceWorkspaceSummary {
        SpacesDeviceWorkspaceSummary(
            id: id, projectID: "proj", projectName: "Project", branch: "doomed", baseBranch: "main", dir: "/project-\(id)", isRunning: false,
            isHidden: false, isDefault: false, sessionCount: 0)
    }
}
