import Foundation

/// A workspace row in the visibility outline.
public struct WorkspaceVisibilityWorkspaceNode: Equatable, Sendable, Identifiable {
    public let workspaceID: String
    public let name: String
    /// The workspace's own hidden flag; the checkbox shows `!isHidden`.
    public let isHidden: Bool
    /// True when the owning project is hidden. The row still shows — and can still toggle — its own
    /// flag, but reads dimmed because the project flag suppresses it in the workspace list regardless.
    public let isDimmed: Bool

    public var id: String { workspaceID }
    public var isChecked: Bool { !isHidden }

    public init(workspaceID: String, name: String, isHidden: Bool, isDimmed: Bool) {
        self.workspaceID = workspaceID
        self.name = name
        self.isHidden = isHidden
        self.isDimmed = isDimmed
    }
}

/// A project row in the visibility outline.
public struct WorkspaceVisibilityProjectNode: Equatable, Sendable, Identifiable {
    /// What a project row's checkbox reflects and toggles.
    public enum Toggle: Equatable, Sendable {
        /// A git project's row toggles the project's own hidden flag.
        case project(isHidden: Bool)
        /// A non-git project has no workspace rows: its single flat row stands in for its one
        /// workspace, matching the collapsed representation both clients' lists use and the Mac sidebar
        /// context menu's Hide. Its checkbox therefore drives that workspace's flag, so exactly one flag
        /// stays in play for non-git projects instead of two that could disagree.
        case workspace(workspaceID: String, isHidden: Bool)

        public var isHidden: Bool {
            switch self {
            case .project(let isHidden): isHidden
            case .workspace(_, let isHidden): isHidden
            }
        }
    }

    public let projectID: String
    public let name: String
    public let isGitRepo: Bool
    public let toggle: Toggle
    /// Child rows. Always empty for a non-git project.
    public let workspaces: [WorkspaceVisibilityWorkspaceNode]
    /// Trailing muted text. Empty for a non-git project, whose row reports no child count.
    public let trailingText: String
    public let isDimmed: Bool

    public var id: String { projectID }
    public var isChecked: Bool { !toggle.isHidden }
    /// Git projects carry child rows; a non-git project is a flat row.
    public var isExpandable: Bool { isGitRepo }

    public init(
        projectID: String, name: String, isGitRepo: Bool, toggle: Toggle, workspaces: [WorkspaceVisibilityWorkspaceNode], trailingText: String,
        isDimmed: Bool
    ) {
        self.projectID = projectID
        self.name = name
        self.isGitRepo = isGitRepo
        self.toggle = toggle
        self.workspaces = workspaces
        self.trailingText = trailingText
        self.isDimmed = isDimmed
    }

    func replacingWorkspaces(_ workspaces: [WorkspaceVisibilityWorkspaceNode]) -> Self {
        Self(
            projectID: projectID, name: name, isGitRepo: isGitRepo, toggle: toggle, workspaces: workspaces, trailingText: trailingText,
            isDimmed: isDimmed)
    }
}

/// A device group header in the visibility outline. Devices are always listed, in sidebar order. Only
/// the Mac lists more than one device at a time, so only its dialog builds this level.
public struct WorkspaceVisibilityDeviceNode: Equatable, Sendable, Identifiable {
    public let deviceID: String
    public let name: String
    public let projects: [WorkspaceVisibilityProjectNode]

    public var id: String { deviceID }

    public init(deviceID: String, name: String, projects: [WorkspaceVisibilityProjectNode]) {
        self.deviceID = deviceID
        self.name = name
        self.projects = projects
    }
}

/// Builds the visibility outline both clients present for choosing what their workspace list shows:
/// device -> project -> workspace on the Mac's Workspaces dialog, project -> workspace on the iOS
/// Workspaces sheet, which speaks for one device at a time.
///
/// Pure, and in a module both clients depend on, so structure, counts, dimming, and search semantics are
/// identical on both and testable without a view. Unlike the workspace lists themselves, the tree
/// deliberately lists everything — hidden projects and hidden workspaces included — because it is the
/// only surface that can bring them back.
public enum WorkspaceVisibilityTree {
    /// One device header's identity, taken from the Mac sidebar's device sections.
    public struct Device: Equatable, Sendable {
        public let deviceID: String
        public let name: String

        public init(deviceID: String, name: String) {
            self.deviceID = deviceID
            self.name = name
        }
    }

    /// A project as the tree reads it. Each client maps its own project model onto this rather than the
    /// tree depending on either client's model: the Mac holds `workspacecore` summaries, iOS holds Device
    /// API summaries, and neither module can be imported by the other.
    public struct Project: Equatable, Sendable {
        public let id: String
        public let name: String
        public let isGitRepo: Bool
        public let isHidden: Bool

        public init(id: String, name: String, isGitRepo: Bool, isHidden: Bool) {
            self.id = id
            self.name = name
            self.isGitRepo = isGitRepo
            self.isHidden = isHidden
        }
    }

    /// A workspace as the tree reads it. See `Project` for why the inputs are the tree's own types.
    public struct Workspace: Equatable, Sendable {
        public let id: String
        public let name: String
        public let isDefault: Bool
        public let isHidden: Bool

        public init(id: String, name: String, isDefault: Bool, isHidden: Bool) {
            self.id = id
            self.name = name
            self.isDefault = isDefault
            self.isHidden = isHidden
        }
    }

    /// The Mac's device -> project -> workspace outline. Projects arrive already grouped by the device
    /// that owns them, so the tree never has to know how a client identifies a project's device.
    public static func build(devices: [Device], projectsByDevice: [String: [Project]], workspacesByProject: [String: [Workspace]], query: String)
        -> [WorkspaceVisibilityDeviceNode]
    {
        let full = devices.map { device in
            WorkspaceVisibilityDeviceNode(
                deviceID: device.deviceID, name: device.name,
                projects: (projectsByDevice[device.deviceID] ?? []).map { projectNode($0, workspacesByProject: workspacesByProject) })
        }
        return filtered(full, query: query)
    }

    /// The project -> workspace outline for a single device, which is what iOS lists: it speaks to one
    /// paired device at a time, so a device level would be a header over the whole list saying what the
    /// device selector already says.
    public static func projectNodes(projects: [Project], workspacesByProject: [String: [Workspace]], query: String)
        -> [WorkspaceVisibilityProjectNode]
    { filtered(projects.map { projectNode($0, workspacesByProject: workspacesByProject) }, query: query, deviceName: nil) }

    private static func projectNode(_ project: Project, workspacesByProject: [String: [Workspace]]) -> WorkspaceVisibilityProjectNode {
        // Sorted the way the Mac sidebar sorts a project's workspaces (default first, then by name) so a
        // row sits in the same place in both surfaces. Hidden workspaces are kept, so the order does
        // not shift as the user toggles them.
        let workspaces = (workspacesByProject[project.id] ?? []).sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        guard project.isGitRepo else {
            // A non-git project has exactly one workspace, so its row toggles that workspace. The
            // project-level flag is never set for a non-git project — no surface offers it — so the
            // row does not reflect one.
            return WorkspaceVisibilityProjectNode(
                projectID: project.id, name: project.name, isGitRepo: false,
                toggle: workspaces.first.map { .workspace(workspaceID: $0.id, isHidden: $0.isHidden) } ?? .project(isHidden: project.isHidden),
                workspaces: [], trailingText: "", isDimmed: false)
        }
        // The count describes the project itself, so it is taken from every child regardless of what
        // the search left showing.
        let shownCount = workspaces.filter { !$0.isHidden }.count
        return WorkspaceVisibilityProjectNode(
            projectID: project.id, name: project.name, isGitRepo: true, toggle: .project(isHidden: project.isHidden),
            workspaces: workspaces.map {
                WorkspaceVisibilityWorkspaceNode(workspaceID: $0.id, name: $0.name, isHidden: $0.isHidden, isDimmed: project.isHidden)
            }, trailingText: project.isHidden ? "project hidden" : "\(shownCount) of \(workspaces.count) shown", isDimmed: project.isHidden)
    }

    private static func filtered(_ devices: [WorkspaceVisibilityDeviceNode], query: String) -> [WorkspaceVisibilityDeviceNode] {
        guard !isBlank(query) else { return devices }
        return devices.compactMap { device in
            let projects = filtered(device.projects, query: query, deviceName: device.name)
            guard !projects.isEmpty else { return nil }
            return WorkspaceVisibilityDeviceNode(deviceID: device.deviceID, name: device.name, projects: projects)
        }
    }

    /// Applies the search query, preserving tree order rather than reordering by score: an outline the
    /// user reads structurally must not reshuffle as they type. Matching is still what decides
    /// membership — `FuzzyTextSearch.match` keeps exactly the candidates that match.
    ///
    /// `deviceName` is the name of the device group the projects sit under, matched at a low weight so a
    /// device search keeps everything on that device. It is `nil` where there is no device level.
    private static func filtered(_ projects: [WorkspaceVisibilityProjectNode], query: String, deviceName: String?) -> [WorkspaceVisibilityProjectNode]
    {
        guard !isBlank(query) else { return projects }
        return projects.compactMap { project -> WorkspaceVisibilityProjectNode? in
            // A project-name match (or a device-name one) keeps the whole project and every child:
            // the user asked for that project, not for a subset of it.
            var projectFields = [FuzzyTextSearch.Field(text: project.name, weight: 1.0)]
            if let deviceName { projectFields.append(.init(text: deviceName, weight: 0.4)) }
            if matches(query: query, fields: projectFields) { return project }
            // Otherwise the project survives only as the ancestor of its own matching workspaces.
            let workspaces = project.workspaces.filter { matches(query: query, fields: [.init(text: $0.name)]) }
            guard !workspaces.isEmpty else { return nil }
            return project.replacingWorkspaces(workspaces)
        }
    }

    private static func matches(query: String, fields: [FuzzyTextSearch.Field]) -> Bool { FuzzyTextSearch.match(query: query, fields: fields) != nil }

    private static func isBlank(_ query: String) -> Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
