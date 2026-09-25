import Foundation

/// What a project *is*, as opposed to what it contains.
///
/// Every project a user adds is `standard`. Exactly one project per daemon is `home`: the daemon-owned
/// place a terminal that belongs to no project lives in, rooted at the account's home directory. The kind
/// is persisted on the project row because it decides behavior no other column can express (the home
/// project cannot be deleted, carries no configuration surface, and is never listed or watched as files)
/// and because a directory alone is not the identity: other projects are allowed to live under the home
/// directory, and the home directory itself may be a git repository.
///
/// The kind deliberately does not encode "non-git". The home project's record stores `isGitRepo == false`,
/// so every existing git/non-git gate in the daemon and the clients already treats it as a plain directory
/// without knowing the kind exists.
public enum ProjectKind: String, Codable, Sendable, CaseIterable {
    case standard
    case home
}

extension ProjectKind {
    /// The home project's name, stored on its record and shown as its title in every client: the
    /// shell's own shorthand for the home directory. It is stored rather than derived per client
    /// because the name is fixed (no surface lets a user edit it), so deriving it separately in the
    /// sidebar, the palette, the iOS list, and the CLI would be four chances to disagree. The
    /// workspace host slug uses the fixed `home` label instead, since `~` is not a DNS label.
    public static let homeProjectName = "~"

    /// The user-facing name of a workspace in a project of this kind: the home project's single workspace
    /// is `~`, a git workspace is its branch, and a non-git workspace (whose `dir` is the project
    /// directory) is its folder name. Derived in one place because four payloads carry the name to a
    /// client (the Mac's `WorkspaceSummary`, the wire's `SpacesDeviceWorkspaceSummary`, the local
    /// profile's `TerminalServiceProfileWorkspaceRecord`, and the CLI row built from either), and the
    /// home case in particular has to read the same in all of them.
    public func workspaceDisplayName(branch: String?, dir: String) -> String {
        if self == .home { return ProjectKind.homeProjectName }
        if let branch, !branch.isEmpty { return branch }
        return (dir as NSString).lastPathComponent
    }

    /// The branch or base-branch metadata a workspace summary reports for a project of this kind: nil for
    /// a home project, whatever the record itself carries otherwise.
    ///
    /// The home project's record stores `isGitRepo == false` and is forced non-git regardless of what its
    /// adopted directory actually is, but the record keeps the branch a pre-existing git repository at that
    /// path was on when it was adopted, since nothing needs the record itself to forget it. Every summary
    /// built from that record has to mask it, or the account's home directory being a git repository (a
    /// dotfiles setup) puts a branch badge on the command palette's and Alerts' `~` row and a `branch=`
    /// value on `spaces workspace list`, both of which a home row has no business showing since it has no
    /// git lifecycle of its own.
    public func maskedBranch(_ branch: String?) -> String? { self == .home ? nil : branch }

    /// Whether a workspace of this project kind has a lifecycle to drive: Start, Restart, and Stop. A home
    /// workspace has none. It is marked running by whatever ad hoc terminal a user opens against it and
    /// stops again when the last one exits, so there are no configured processes for Start to launch and
    /// nothing for Stop or Restart to act on; the daemon refuses all three for it. Every client surface
    /// that could offer one reads this property: the Mac workspace footer, the sidebar row's context
    /// menu, and the workspace panel's empty state (all three through
    /// `AppKitController.workspaceLifecycleControlsOfferStart` for Start itself), plus the iOS workspace
    /// control bar. No surface can offer a control the daemon would reject.
    public var hasWorkspaceLifecycle: Bool { self != .home }

    /// Whether a workspace of this project kind can host the Editor. A home workspace has no Editor: the
    /// daemon refuses its file listing and reads (the same rule `openWorkspaceEditor`'s direct-open guard
    /// enforces client-side), so a code pane pointed at one can only fail. Every other place that can
    /// select or retain the Editor's target workspace, the fallback chain
    /// (`AppKitController.globalEditorFallbackWorkspaceID`) and every keep set built from an installed
    /// overview (`OpenPanePruning.editorEligibleWorkspaceIDs`, shared by startup restoration and the
    /// live overview-driven prune), reads this one property instead of re-deriving the exclusion, so
    /// they can never drift apart.
    public var isEditorEligible: Bool { self != .home }

    /// Whether a workspace of this project kind can be an automation's target. A home workspace cannot: the
    /// home project supports terminals and nothing else, so it has no Stop to cancel a queued run with and
    /// no settings surface to reach an automation's workspace from. The daemon refuses it in
    /// `AutomationService.validateWorkspaceTarget` and the Mac editor's workspace picker leaves it out
    /// (`AutomationsViewModel.visibleWorkspaceChoices`), both reading this one property.
    public var isAutomationTargetEligible: Bool { self != .home }
}
