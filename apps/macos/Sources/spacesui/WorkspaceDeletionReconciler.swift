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
    /// exactly like an ordinary overview refresh — this type never applies state itself. Returns
    /// whether `workspaceID` is still present once the budget is spent (or every fetch failed) —
    /// `false` means the delete is confirmed complete.
    func reconcile(workspaceID: String, fetchOverview: () async -> SpacesDeviceOverviewPayload?, applyOverview: (SpacesDeviceOverviewPayload) -> Void)
        async -> Bool
    {
        for attempt in 0..<Self.attempts {
            guard let overview = await fetchOverview() else {
                if attempt + 1 < Self.attempts { try? await Task.sleep(for: interval) }
                continue
            }
            applyOverview(overview)
            guard overview.workspaces.contains(where: { $0.id == workspaceID }) else { return false }
            if attempt + 1 < Self.attempts { try? await Task.sleep(for: interval) }
        }
        return true
    }
}
