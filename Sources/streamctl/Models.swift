import Foundation

public struct Project: Codable, Sendable {
    public let id: UUID
    public let name: String
    public let repoRoot: String

    public init(id: UUID, name: String, repoRoot: String) {
        self.id = id
        self.name = name
        self.repoRoot = repoRoot
    }
}

public struct Stream: Codable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let name: String
    public let worktreePath: String
    public let displayIndex: Int
    public let spaceIndex: Int

    public init(id: UUID, projectID: UUID, name: String, worktreePath: String, displayIndex: Int, spaceIndex: Int) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.worktreePath = worktreePath
        self.displayIndex = displayIndex
        self.spaceIndex = spaceIndex
    }
}

public struct StreamSummary: Sendable {
    public let name: String
    public let worktreePath: String
    public let isActive: Bool
    public let displayIndex: Int
    public let spaceIndex: Int

    public init(name: String, worktreePath: String, isActive: Bool, displayIndex: Int, spaceIndex: Int) {
        self.name = name
        self.worktreePath = worktreePath
        self.isActive = isActive
        self.displayIndex = displayIndex
        self.spaceIndex = spaceIndex
    }
}

public struct ActiveStreamSummary: Sendable {
    public let projectName: String
    public let streamName: String
    public let worktreePath: String
    public let activatedAt: String
    public let displayIndex: Int
    public let spaceIndex: Int

    public init(projectName: String, streamName: String, worktreePath: String, activatedAt: String, displayIndex: Int, spaceIndex: Int) {
        self.projectName = projectName
        self.streamName = streamName
        self.worktreePath = worktreePath
        self.activatedAt = activatedAt
        self.displayIndex = displayIndex
        self.spaceIndex = spaceIndex
    }
}

public struct StreamWindowIdentity: Codable, Sendable {
    public let streamID: UUID
    public let windows: [WindowIdentity]
    public let updatedAt: String

    public init(streamID: UUID, windows: [WindowIdentity], updatedAt: String) {
        self.streamID = streamID
        self.windows = windows
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case streamID, windows, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        streamID = try c.decode(UUID.self, forKey: .streamID)
        windows = try c.decodeIfPresent([WindowIdentity].self, forKey: .windows) ?? []
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
    }
}

public struct WindowIdentity: Codable, Sendable {
    public let id: Int
    public let app: String
    public let title: String?
    public let space: Int
    public let display: Int

    public init(id: Int, app: String, title: String?, space: Int, display: Int) {
        self.id = id
        self.app = app
        self.title = title
        self.space = space
        self.display = display
    }
}

public struct StreamDoctorReport: Sendable {
    public let projectName: String
    public let streamName: String
    public let worktreePath: String
    public let displayIndex: Int
    public let spaceIndex: Int
    public let yabaiAvailable: Bool
    public let windowsFound: Int
    public let windowsExpected: Int
    public let missingWindowIDs: [Int]

    public init(
        projectName: String,
        streamName: String,
        worktreePath: String,
        displayIndex: Int,
        spaceIndex: Int,
        yabaiAvailable: Bool,
        windowsFound: Int,
        windowsExpected: Int,
        missingWindowIDs: [Int]
    ) {
        self.projectName = projectName
        self.streamName = streamName
        self.worktreePath = worktreePath
        self.displayIndex = displayIndex
        self.spaceIndex = spaceIndex
        self.yabaiAvailable = yabaiAvailable
        self.windowsFound = windowsFound
        self.windowsExpected = windowsExpected
        self.missingWindowIDs = missingWindowIDs
    }
}

public struct SpaceOption: Sendable {
    public let displayIndex: Int
    public let spaceIndex: Int

    public init(displayIndex: Int, spaceIndex: Int) {
        self.displayIndex = displayIndex
        self.spaceIndex = spaceIndex
    }
}
