import SwiftUI
import spacesdevicecore

/// Confirms deleting a workspace, mirroring the Mac's delete alert. It is a sheet rather than an
/// `.alert` because the branch choices are toggles, which an alert cannot host.
///
/// Both branch toggles default to off: deleting the workspace is recoverable work (the branch still
/// holds the commits), deleting the branch is not.
struct WorkspaceDeleteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let workspace: SpacesDeviceWorkspaceSummary
    let onConfirm: (_ deleteLocalBranch: Bool, _ deleteRemoteBranch: Bool) -> Void

    @State private var deleteLocalBranch = false
    @State private var deleteRemoteBranch = false

    /// The branch this workspace's worktree sits on, when the daemon reported one. A non-git workspace
    /// has none, and there is nothing to offer to delete.
    private var branch: String? {
        guard let branch = workspace.branch, !branch.isEmpty else { return nil }
        return branch
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(workspace.displayName).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("Stops the workspace, removes its git worktree, and removes the workspace and its settings from Spaces.").font(
                        .system(size: 13)
                    ).foregroundStyle(Theme.mutedSecondary)
                }
                if let branch {
                    Section {
                        Toggle("Delete local branch (\(branch))", isOn: $deleteLocalBranch).accessibilityIdentifier("workspace.delete.localBranch")
                        Toggle("Delete remote branch (\(branch))", isOn: $deleteRemoteBranch).accessibilityIdentifier("workspace.delete.remoteBranch")
                    }
                }
            }.navigationTitle("Delete workspace?").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("workspace.delete.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delete", role: .destructive) {
                        onConfirm(deleteLocalBranch, deleteRemoteBranch)
                        dismiss()
                    }.accessibilityIdentifier("workspace.delete.confirm")
                }
            }
        }.presentationDetents([.medium]).tint(Theme.accent)
    }
}
