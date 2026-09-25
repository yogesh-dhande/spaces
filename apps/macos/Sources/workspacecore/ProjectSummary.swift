import Foundation
import spacesdevicecore

public struct ProjectSummary: Hashable, Sendable {
    public let id: String
    public let name: String
    public let dir: String
    public let isGitRepo: Bool
    public let defaultBranch: String?
    /// Whether this is an ordinary project or the daemon's own home project. Clients read it to give the
    /// home row its glyph and to leave out the surfaces a home project does not have.
    public let kind: ProjectKind
    /// The project's own hidden flag, independent of each workspace's. Composing the two into an
    /// effective visibility is the caller's job.
    public let isHidden: Bool
    public var isCollapsed: Bool
    public let deviceID: String

    public init(
        id: String, name: String, dir: String, isGitRepo: Bool, defaultBranch: String?, kind: ProjectKind = .standard, isHidden: Bool = false,
        isCollapsed: Bool = false, deviceID: String = SpacesDeviceRecord.localDeviceID
    ) {
        self.id = id
        self.name = name
        self.dir = dir
        self.isGitRepo = isGitRepo
        self.defaultBranch = defaultBranch
        self.kind = kind
        self.isHidden = isHidden
        self.isCollapsed = isCollapsed
        self.deviceID = deviceID
    }
}
