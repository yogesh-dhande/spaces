import Foundation
import appctl
import winmove

public struct Project: Codable, Sendable {
    public let id: UUID
    public let name: String
    public let repoRoot: String
    public let defaultEditor: EditorKind
    public let defaultBrowser: BrowserKind
    public let defaultTerminal: TerminalKind
    public let editorLayout: WindowLayout
    public let browserLayout: WindowLayout
    public let windows: [ProjectWindowSpec]
    public let browserTabs: [String]

    public init(
        id: UUID,
        name: String,
        repoRoot: String,
        defaultEditor: EditorKind,
        defaultBrowser: BrowserKind,
        defaultTerminal: TerminalKind,
        editorLayout: WindowLayout,
        browserLayout: WindowLayout,
        windows: [ProjectWindowSpec],
        browserTabs: [String]
    ) {
        self.id = id
        self.name = name
        self.repoRoot = repoRoot
        self.defaultEditor = defaultEditor
        self.defaultBrowser = defaultBrowser
        self.defaultTerminal = defaultTerminal
        self.editorLayout = editorLayout
        self.browserLayout = browserLayout
        self.windows = windows
        self.browserTabs = browserTabs
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, repoRoot, defaultEditor, defaultBrowser, defaultTerminal
        case editorLayout, browserLayout, windows, browserTabs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        repoRoot = try c.decode(String.self, forKey: .repoRoot)
        defaultEditor = try c.decode(EditorKind.self, forKey: .defaultEditor)
        defaultBrowser = try c.decode(BrowserKind.self, forKey: .defaultBrowser)
        defaultTerminal = try c.decode(TerminalKind.self, forKey: .defaultTerminal)
        editorLayout = try c.decode(WindowLayout.self, forKey: .editorLayout)
        browserLayout = try c.decode(WindowLayout.self, forKey: .browserLayout)
        windows = try c.decodeIfPresent([ProjectWindowSpec].self, forKey: .windows) ?? []
        browserTabs = try c.decodeIfPresent([String].self, forKey: .browserTabs) ?? []
    }
}

public enum ProjectWindowKind: String, Codable, Sendable {
    case editor
    case browser
    case terminal
    case custom
}

public struct ProjectWindowSpec: Codable, Sendable {
    public let name: String
    public let kind: ProjectWindowKind
    public let bundleID: String
    public let layout: WindowLayout
    public let launchCommand: String?
    public let command: String?
    public let urls: [String]
    public let matchTitle: String?
    public let editorKind: String?

    public init(
        name: String,
        kind: ProjectWindowKind,
        bundleID: String,
        layout: WindowLayout,
        launchCommand: String?,
        command: String?,
        urls: [String],
        matchTitle: String?,
        editorKind: String?
    ) {
        self.name = name
        self.kind = kind
        self.bundleID = bundleID
        self.layout = layout
        self.launchCommand = launchCommand
        self.command = command
        self.urls = urls
        self.matchTitle = matchTitle
        self.editorKind = editorKind
    }
}

public struct Stream: Codable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let name: String
    public let worktreePath: String

    public init(id: UUID, projectID: UUID, name: String, worktreePath: String) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.worktreePath = worktreePath
    }
}

public struct StreamSummary: Sendable {
    public let name: String
    public let worktreePath: String
    public let isActive: Bool

    public init(name: String, worktreePath: String, isActive: Bool) {
        self.name = name
        self.worktreePath = worktreePath
        self.isActive = isActive
    }
}

public struct ActiveStreamSummary: Sendable {
    public let projectName: String
    public let streamName: String
    public let worktreePath: String
    public let activatedAt: String

    public init(projectName: String, streamName: String, worktreePath: String, activatedAt: String) {
        self.projectName = projectName
        self.streamName = streamName
        self.worktreePath = worktreePath
        self.activatedAt = activatedAt
    }
}

public struct StreamWindowIdentity: Codable, Sendable {
    public let streamID: UUID
    public let windows: [WindowIdentity]
    public let updatedAt: String

    public init(
        streamID: UUID,
        windows: [WindowIdentity],
        updatedAt: String
    ) {
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
    public let name: String
    public let bundleID: String
    public let windowID: Int?
    public let windowTitle: String?
    public let anchorURL: String?

    public init(name: String, bundleID: String, windowID: Int?, windowTitle: String?, anchorURL: String?) {
        self.name = name
        self.bundleID = bundleID
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.anchorURL = anchorURL
    }
}

public struct StreamDoctorReport: Sendable {
    public let projectName: String
    public let streamName: String
    public let worktreePath: String
    public let identityUpdatedAt: String?
    public let foundWindowCount: Int
    public let expectedWindowCount: Int
    public let missingWindows: [String]

    public init(
        projectName: String,
        streamName: String,
        worktreePath: String,
        identityUpdatedAt: String?,
        foundWindowCount: Int,
        expectedWindowCount: Int,
        missingWindows: [String]
    ) {
        self.projectName = projectName
        self.streamName = streamName
        self.worktreePath = worktreePath
        self.identityUpdatedAt = identityUpdatedAt
        self.foundWindowCount = foundWindowCount
        self.expectedWindowCount = expectedWindowCount
        self.missingWindows = missingWindows
    }
}
