import SwiftUI
import spacesdevicecore

/// Chooses what the Spaces tab lists, and is the only surface that lists what it is already hiding —
/// the iOS counterpart of the Mac's Workspaces dialog, built from the same `WorkspaceVisibilityTree`.
///
/// Everything the device reports is listed and expanded: a hidden project or workspace reads dimmed with
/// an unchecked box rather than being left out, because a row the user came here to recover must be
/// findable. There is no device level — this app speaks to one paired device at a time, and the device
/// selector on the tab behind already says which.
struct WorkspaceVisibilitySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: SpacesMobileAppModel
    /// Reset on every presentation (this is `@State` on a sheet that is created fresh each time), so the
    /// sheet always opens on the whole list rather than on the last search.
    @State private var query = ""

    private var projects: [WorkspaceVisibilityProjectNode] { model.workspaceVisibilityProjects(query: query) }

    var body: some View {
        NavigationStack {
            List {
                Section { searchField.padding(.horizontal, 20).padding(.vertical, 12).bandListRow().id("visibility.search") }
                if projects.isEmpty {
                    Section {
                        ContentUnavailableView(
                            query.isEmpty ? "No Workspaces" : "No Matches", systemImage: "rectangle.stack",
                            description: Text(query.isEmpty ? "This device has no projects yet." : "No project or workspace matches this search.")
                        ).frame(maxWidth: .infinity, minHeight: 280).bandListRow().id("visibility.empty")
                    }
                } else {
                    // Each row is its own section, as on the Spaces tab: a row leaving a surviving section
                    // is the update the collection view miscounts, and search adds and removes rows here on
                    // every keystroke.
                    ForEach(projects) { project in
                        Section { projectBand(project) }
                        ForEach(project.workspaces) { workspace in Section { workspaceRow(workspace, in: project) } }
                    }
                }
            }.listStyle(.plain).listSectionSpacing(0).background(Theme.bg).scrollContentBackground(.hidden).navigationTitle("Workspaces")
                .navigationBarTitleDisplayMode(.inline).toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("visibility.done") }
                }
        }.tint(Theme.accent).accessibilityIdentifier("visibility.sheet")
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.mutedSecondary)
            TextField("Search projects and workspaces", text: $query).font(.system(size: 13)).textInputAutocapitalization(.never)
                .autocorrectionDisabled().accessibilityIdentifier("visibility.search")
        }.padding(.horizontal, 10).frame(height: 36).background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Rows

    /// A project's band. A git project's box drives the project's own flag and the band reports how many
    /// of its workspaces are shown; a non-git project has no workspace rows of its own, so its band stands
    /// in for its single workspace and its box drives that workspace's flag.
    private func projectBand(_ project: WorkspaceVisibilityProjectNode) -> some View {
        Button {
            toggle(project)
        } label: {
            HeaderBand {
                VisibilityCheckbox(isChecked: project.isChecked)
                Text(project.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
                if !project.trailingText.isEmpty {
                    Text(project.trailingText).font(.system(size: 11)).foregroundStyle(Theme.mutedSecondary).lineLimit(1)
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.isMutating).opacity(project.isChecked ? 1 : 0.55).accessibilityIdentifier(
            "visibility.project.\(project.projectID)"
        ).accessibilityValue(project.isChecked ? "Shown" : "Hidden").bandListHeaderRow().id("visibility.project.\(project.projectID)")
    }

    /// One workspace row. A workspace under a hidden project keeps its own box and stays toggleable —
    /// dimming is what says the project's flag, not this one's, is suppressing it.
    private func workspaceRow(_ workspace: WorkspaceVisibilityWorkspaceNode, in project: WorkspaceVisibilityProjectNode) -> some View {
        Button {
            Task { await model.setWorkspaceHidden(workspaceID: workspace.workspaceID, isHidden: workspace.isChecked) }
        } label: {
            HStack(spacing: 10) {
                VisibilityCheckbox(isChecked: workspace.isChecked)
                Text(workspace.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.vertical, 9).padding(.leading, 32).padding(.trailing, 20).frame(maxWidth: .infinity, alignment: .leading).contentShape(
                Rectangle())
        }.buttonStyle(.plain).disabled(model.isMutating).opacity(workspace.isChecked && !workspace.isDimmed ? 1 : 0.55).accessibilityIdentifier(
            "visibility.workspace.\(workspace.workspaceID)"
        ).accessibilityValue(workspace.isChecked ? "Shown" : "Hidden").bandListRow().id("visibility.workspace.\(workspace.workspaceID)")
    }

    // MARK: - Actions

    /// Every toggle fires directly, hide and unhide alike: a hide changes only the hidden flag, never run
    /// state, so there is nothing to confirm.
    private func toggle(_ project: WorkspaceVisibilityProjectNode) {
        switch project.toggle {
        case .project(let isHidden): Task { await model.setProjectHidden(projectID: project.projectID, isHidden: !isHidden) }
        case .workspace(let workspaceID, let isHidden): Task { await model.setWorkspaceHidden(workspaceID: workspaceID, isHidden: !isHidden) }
        }
    }
}

/// The sheet's checkbox. Checked means the row is shown in the workspace list.
private struct VisibilityCheckbox: View {
    let isChecked: Bool

    var body: some View {
        Image(systemName: isChecked ? "checkmark.square.fill" : "square").font(.system(size: 16, weight: .medium)).foregroundStyle(
            isChecked ? Theme.accent : Theme.mutedSecondary)
    }
}
