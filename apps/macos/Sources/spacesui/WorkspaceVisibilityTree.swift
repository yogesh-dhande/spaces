import Foundation
import workspacecore

/// A workspace row in the visibility outline.
struct WorkspaceVisibilityWorkspaceNode: Equatable, Sendable {
    let workspaceID: String
    let name: String
    /// The workspace's own hidden flag; the checkbox shows `!isHidden`.
    let isHidden: Bool
    /// True when the owning project is hidden. The row still shows — and can still toggle — its own
    /// flag, but reads dimmed because the project flag suppresses it in the sidebar regardless.
    let isDimmed: Bool

    var isChecked: Bool { !isHidden }
}

/// A project row in the visibility outline.
struct WorkspaceVisibilityProjectNode: Equatable, Sendable {
    /// What a project row's checkbox reflects and toggles.
    enum Toggle: Equatable, Sendable {
        /// A git project's row toggles the project's own hidden flag.
        case project(isHidden: Bool)
        /// A non-git project has no workspace rows: its single flat row stands in for its one
        /// workspace, matching the sidebar's collapsed representation and the sidebar context menu's
        /// Hide. Its checkbox therefore drives that workspace's flag, so exactly one flag stays in
        /// play for non-git projects instead of two that could disagree.
        case workspace(workspaceID: String, isHidden: Bool)

        var isHidden: Bool {
            switch self {
            case .project(let isHidden): isHidden
            case .workspace(_, let isHidden): isHidden
            }
        }
    }

    let projectID: String
    let deviceID: String
    let name: String
    let isGitRepo: Bool
    let toggle: Toggle
    /// Child rows. Always empty for a non-git project.
    let workspaces: [WorkspaceVisibilityWorkspaceNode]
    /// Trailing muted text. Empty for a non-git project, whose row reports no child count.
    let trailingText: String
    let isDimmed: Bool

    var isChecked: Bool { !toggle.isHidden }
    /// Git projects carry a disclosure triangle and child rows; a non-git project is a flat row.
    var isExpandable: Bool { isGitRepo }

    func replacingWorkspaces(_ workspaces: [WorkspaceVisibilityWorkspaceNode]) -> Self {
        Self(
            projectID: projectID, deviceID: deviceID, name: name, isGitRepo: isGitRepo, toggle: toggle, workspaces: workspaces,
            trailingText: trailingText, isDimmed: isDimmed)
    }
}

/// A device group header in the visibility outline. Devices are always listed, in sidebar order.
struct WorkspaceVisibilityDeviceNode: Equatable, Sendable {
    let deviceID: String
    let name: String
    let projects: [WorkspaceVisibilityProjectNode]
}

/// Builds the Workspaces dialog's device -> project -> workspace outline.
///
/// Pure so the dialog's structure, counts, dimming, and search semantics are testable without an
/// outline view. Unlike the sidebar, the tree deliberately lists everything — hidden projects and
/// hidden workspaces included — because the dialog is the only surface that can bring them back.
enum WorkspaceVisibilityTree {
    /// One device header's identity, taken from the sidebar's device sections.
    struct Device: Equatable, Sendable {
        let deviceID: String
        let name: String

        init(deviceID: String, name: String) {
            self.deviceID = deviceID
            self.name = name
        }
    }

    static func build(
        devices: [Device], projects: [ProjectSummary], workspacesByProject: [String: [WorkspaceSummary]], query: String
    ) -> [WorkspaceVisibilityDeviceNode] {
        let full = devices.map { device in
            WorkspaceVisibilityDeviceNode(
                deviceID: device.deviceID, name: device.name,
                projects: projects.filter { $0.deviceID == device.deviceID }.map { projectNode($0, device: device, workspacesByProject: workspacesByProject) })
        }
        return filtered(full, query: query)
    }

    private static func projectNode(
        _ project: ProjectSummary, device: Device, workspacesByProject: [String: [WorkspaceSummary]]
    ) -> WorkspaceVisibilityProjectNode {
        // Sorted the way the sidebar sorts a project's workspaces (default first, then by name) so a
        // row sits in the same place in both surfaces. Hidden workspaces are kept, so the order does
        // not shift as the user toggles them.
        let workspaces = (workspacesByProject[project.id] ?? []).sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        guard project.isGitRepo else {
            // A non-git project has exactly one workspace, so its row toggles that workspace. The
            // project-level flag is never set for a non-git project — no surface offers it — so the
            // row does not reflect one.
            return WorkspaceVisibilityProjectNode(
                projectID: project.id, deviceID: device.deviceID, name: project.name, isGitRepo: false,
                toggle: workspaces.first.map { .workspace(workspaceID: $0.id, isHidden: $0.isHidden) } ?? .project(isHidden: project.isHidden),
                workspaces: [], trailingText: "", isDimmed: false)
        }
        // The count describes the project itself, so it is taken from every child regardless of what
        // the search left showing.
        let shownCount = workspaces.filter { !$0.isHidden }.count
        return WorkspaceVisibilityProjectNode(
            projectID: project.id, deviceID: device.deviceID, name: project.name, isGitRepo: true, toggle: .project(isHidden: project.isHidden),
            workspaces: workspaces.map {
                WorkspaceVisibilityWorkspaceNode(workspaceID: $0.id, name: $0.displayName, isHidden: $0.isHidden, isDimmed: project.isHidden)
            },
            trailingText: project.isHidden ? "project hidden" : "\(shownCount) of \(workspaces.count) shown", isDimmed: project.isHidden)
    }

    /// Applies the search query, preserving tree order rather than reordering by score: an outline the
    /// user reads structurally must not reshuffle as they type. Ranking is still what decides
    /// membership — `CommandPaletteFuzzySearch.rank` keeps exactly the candidates that match.
    private static func filtered(_ devices: [WorkspaceVisibilityDeviceNode], query: String) -> [WorkspaceVisibilityDeviceNode] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return devices }
        return devices.compactMap { device in
            let projects = device.projects.compactMap { project -> WorkspaceVisibilityProjectNode? in
                // A project-name match (or a device-name one) keeps the whole project and every child:
                // the user asked for that project, not for a subset of it.
                if matches(query: query, fields: [.init(text: project.name, weight: 1.0), .init(text: device.name, weight: 0.4)]) { return project }
                // Otherwise the project survives only as the ancestor of its own matching workspaces.
                let workspaces = project.workspaces.filter { matches(query: query, fields: [.init(text: $0.name)]) }
                guard !workspaces.isEmpty else { return nil }
                return project.replacingWorkspaces(workspaces)
            }
            guard !projects.isEmpty else { return nil }
            return WorkspaceVisibilityDeviceNode(deviceID: device.deviceID, name: device.name, projects: projects)
        }
    }

    private static func matches(query: String, fields: [CommandPaletteFuzzySearch.Field]) -> Bool {
        CommandPaletteFuzzySearch.match(query: query, fields: fields) != nil
    }
}
