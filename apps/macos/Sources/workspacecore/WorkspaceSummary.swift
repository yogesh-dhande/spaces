import Foundation
import spacesdevicecore

public struct WorkspaceSummary: Hashable, Sendable {
    public let id: String
    public let branch: String?
    public let baseBranch: String?
    public let dir: String
    public let isRunning: Bool
    public let isHidden: Bool
    public let isDefault: Bool
    public let notes: String?
    /// The kind of the project this workspace belongs to. Carried here because the workspace's own
    /// display name depends on it and the surfaces that show that name (the panel footer, tab titles,
    /// the palette) hold a workspace without its project.
    public let projectKind: ProjectKind
    public let deviceID: String

    public init(
        id: String, branch: String?, baseBranch: String? = nil, dir: String, isRunning: Bool, isHidden: Bool = false, isDefault: Bool,
        notes: String? = nil, projectKind: ProjectKind = .standard, deviceID: String = SpacesDeviceRecord.localDeviceID
    ) {
        self.id = id
        self.branch = branch
        self.baseBranch = baseBranch
        self.dir = dir
        self.isRunning = isRunning
        self.isHidden = isHidden
        self.isDefault = isDefault
        self.notes = notes
        self.projectKind = projectKind
        self.deviceID = deviceID
    }

    /// Name shown in the sidebar, detail pane, and search, derived by the owning project's kind so every
    /// surface that names a workspace agrees: the home project's single workspace reads `~` instead of the
    /// home folder's name, which would otherwise be the account's user name.
    public var displayName: String { projectKind.workspaceDisplayName(branch: branch, dir: dir) }
}
