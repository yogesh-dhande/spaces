import spacesclientcore
import spacesdevicecore
import spacesterminalcore

/// One coding agent the code pane can send a review comment/batch to: `id` names the agent row (for
/// stable dropdown selection across refreshes), `label` is its display name, `sessionID` is the
/// terminal session `workspaceReviewCommentsSend` writes into.
struct CodePaneRunningAgent: Equatable {
    let id: String
    let label: String
    let sessionID: String
}

/// Host-side lookups a code pane's bridge needs to service an RPC, kept as a narrow protocol so
/// `CodePaneContentController` can be constructed with a test double instead of a live
/// `AppKitController`.
@MainActor protocol CodePaneHosting: AnyObject {
    /// The device this workspace lives on, resolved fresh on every call (never cached by the
    /// caller) so a code pane left open across an endpoint or pairing change picks up the new
    /// device instead of pinning whatever was true when the pane opened — the same freshness
    /// `AppKitController.deviceForWorkspaceMutation` gives every other workspace-scoped action.
    /// `nil` when the workspace's device cannot presently service a daemon action.
    ///
    /// Workspace ids are `UUID().uuidString` values, globally unique across every device, so the
    /// id alone is sufficient to identify the owning device — there is no cross-device collision
    /// to disambiguate. Routing by id here matches `deviceForWorkspaceMutation`, the chokepoint
    /// every other workspace-scoped action already routes through.
    func codePaneDevice(workspaceID: String) -> SpacesPairedDeviceRecord?

    /// The workspace's display name and configured base branch (`nil` if none configured), for
    /// the `spaces:init` payload and for resolving a `.baseBranch` diff scope.
    func codePaneWorkspaceInfo(workspaceID: String) -> (name: String, baseBranch: String?)?

    /// The app's current effective light/dark appearance, for the `spaces:init` payload at
    /// construction time. Subsequent changes arrive through `CodePaneContentController.applyAppearance`,
    /// called by `PanelCoordinator.broadcastAppearance` — the same seam terminal panes use.
    func codePaneCurrentAppearance() -> ThemeAppearance

    /// Coding agents currently running in this workspace, for the pane's assigned-agent selection
    /// (auto-default when exactly one runs, a dropdown otherwise; sending disabled when none do).
    func codePaneRunningAgents(workspaceID: String) -> [CodePaneRunningAgent]
}

extension AppKitController: CodePaneHosting {
    func codePaneDevice(workspaceID: String) -> SpacesPairedDeviceRecord? { deviceForWorkspaceMutation(workspaceID: workspaceID) }

    func codePaneWorkspaceInfo(workspaceID: String) -> (name: String, baseBranch: String?)? {
        guard let (_, workspace) = findWorkspace(id: workspaceID) else { return nil }
        return (workspace.displayName, workspace.baseBranch)
    }

    func codePaneCurrentAppearance() -> ThemeAppearance { Self.resolvedThemeAppearance() }

    /// `codePaneWorkspaceInfo` resolves through the merged, device-agnostic `WorkspaceSummary`
    /// (`findWorkspace(id:)`), which carries no agent rows, so this instead reuses
    /// `deviceWorkspaceSummary`, the scan over each device section's raw overview that other agent-row
    /// readers (e.g. `clientWorkspaceID(forTerminalSession:)`) already use.
    ///
    /// A row with `runState == .running` but a `nil` `sessionID` (no session behind the agent yet) is
    /// filtered out: sending needs a session id to write into, so such a row cannot be a valid target.
    func codePaneRunningAgents(workspaceID: String) -> [CodePaneRunningAgent] {
        guard let workspace = deviceWorkspaceSummary(workspaceID: workspaceID) else { return [] }
        return workspace.codingAgentRows.compactMap { row in
            guard row.runState == .running, let sessionID = row.sessionID else { return nil }
            return CodePaneRunningAgent(id: row.id, label: row.name, sessionID: sessionID)
        }
    }
}
