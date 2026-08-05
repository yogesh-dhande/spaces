import Foundation
import spacesdevicecore

/// Reconciles an indeterminate `deleteWorkspace` failure against fresh overviews from the workspace's
/// owning device, mirroring `SpacesMobileAppModel.reconcileWorkspaceDeletionOutcome` on iOS.
///
/// `AppKitController.deleteWorkspace` treats a failure as a definitive rejection only when
/// `AppKitController.isIndeterminateDeleteOutcome` says the daemon actually answered it. Every other
/// failure leaves the delete's fate unknown: the daemon runs a delete's teardown (stop, worktree
/// removal, record drop) on its own queue, and it can still be working through that well past this
/// request's own timeout. Un-marking the row and reporting failure in that window would let the user
/// retry-delete a workspace that is already doomed, so this refetches the overview a bounded number of
/// times instead, giving an in-flight delete a chance to resolve to success before a spurious failure
/// is surfaced.
///
/// Performs no I/O of its own — `fetchOverview` and `applyOverview` are supplied by the caller, so the
/// reconciliation decision (how many attempts, when to stop early, what counts as resolved) is
/// testable without a real device connection.
@MainActor final class WorkspaceDeletionReconciler {
    /// The reconciliation verdict once the attempt budget is spent (or an overview resolves early).
    /// Three-valued rather than a "still present" `Bool` because a failed transport for every single
    /// attempt proves nothing — `gone`/`present` both require at least one overview to have actually
    /// resolved, so a caller can tell "the daemon proved the delete landed/didn't" apart from "nothing
    /// ever answered" and avoid fabricating either verdict from silence.
    enum Outcome: Equatable {
        /// An overview resolved and did not list the workspace: the delete is confirmed complete.
        case gone
        /// An overview resolved and still listed the workspace once the budget was spent.
        case present
        /// Every fetch failed — the transport never answered, so neither verdict is provable. The
        /// caller must not un-mark the row on this; it has to keep waiting for real evidence.
        case unknown
    }

    /// Reconciliation attempts after an indeterminate delete failure. Five attempts at `interval` give
    /// the daemon a settle window on the order of the sidebar's own poll cadence rather than an
    /// instant verdict — matching the constant iOS uses for the same wait.
    static let attempts = 5

    /// Interval between reconciliation refetches. `var` rather than a fixed constant so tests can
    /// shrink the whole curve, matching `RemoteOverviewSubscriptionCoordinator.retryDelay` and
    /// `TerminalStateStreamReconnectBackoff.retryDelay`.
    var interval: Duration = .seconds(2)

    /// Refetches the overview up to `Self.attempts` times. `fetchOverview` returning `nil` means the
    /// refetch itself failed (the transport is still down); that is inconclusive rather than evidence
    /// either way, so the loop just tries again on its next attempt. Every overview that does resolve
    /// is handed to `applyOverview` so the caller can publish it through its normal refresh path,
    /// exactly like an ordinary overview refresh — this type never applies state itself. See `Outcome`
    /// for what the return value means.
    ///
    /// Only an overview that lists the workspace while the daemon reports NO teardown in flight for it
    /// counts as evidence the delete failed. A workspace the daemon says it is still tearing down is not
    /// failure evidence at all, however many probes see it — the budget then ends in `.unknown`, and the
    /// caller keeps deferring rather than telling the user a workspace survived that is about to go.
    func reconcile(workspaceID: String, fetchOverview: () async -> SpacesDeviceOverviewPayload?, applyOverview: (SpacesDeviceOverviewPayload) -> Void)
        async -> Outcome
    {
        var sawWorkspaceListedWithNoTeardownRunning = false
        for attempt in 0..<Self.attempts {
            guard let overview = await fetchOverview() else {
                if attempt + 1 < Self.attempts { try? await Task.sleep(for: interval) }
                continue
            }
            applyOverview(overview)
            guard overview.workspaces.contains(where: { $0.id == workspaceID }) else { return .gone }
            // Still listed, but the daemon says it is tearing this workspace down right now — a slow stop
            // script outliving this budget looks exactly like a failed delete from here, and only the
            // daemon can tell them apart. Not evidence of failure, so it does not make this `.present`.
            if !overview.workspaceIDsWithTeardownInFlight.contains(workspaceID) { sawWorkspaceListedWithNoTeardownRunning = true }
            if attempt + 1 < Self.attempts { try? await Task.sleep(for: interval) }
        }
        return sawWorkspaceListedWithNoTeardownRunning ? .present : .unknown
    }
}
