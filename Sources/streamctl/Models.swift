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
    public let terminals: [TerminalSpec]
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
        terminals: [TerminalSpec],
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
        self.terminals = terminals
        self.browserTabs = browserTabs
    }
}

public struct TerminalSpec: Codable, Sendable {
    public let layout: WindowLayout
    public let command: String?

    public init(layout: WindowLayout, command: String?) {
        self.layout = layout
        self.command = command
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
    public let editorMatchTitle: String?
    public let chromeAnchorURL: String?
    public let terminalTitlePrefix: String?
    public let updatedAt: String

    public init(
        streamID: UUID,
        editorMatchTitle: String?,
        chromeAnchorURL: String?,
        terminalTitlePrefix: String?,
        updatedAt: String
    ) {
        self.streamID = streamID
        self.editorMatchTitle = editorMatchTitle
        self.chromeAnchorURL = chromeAnchorURL
        self.terminalTitlePrefix = terminalTitlePrefix
        self.updatedAt = updatedAt
    }
}

public struct StreamDoctorReport: Sendable {
    public let projectName: String
    public let streamName: String
    public let worktreePath: String
    public let editorMatchTitle: String?
    public let chromeAnchorURL: String?
    public let terminalTitlePrefix: String?
    public let identityUpdatedAt: String?
    public let editorWindowFound: Bool
    public let chromeWindowFound: Bool
    public let terminalWindowCount: Int
    public let expectedTerminalWindowCount: Int

    public init(
        projectName: String,
        streamName: String,
        worktreePath: String,
        editorMatchTitle: String?,
        chromeAnchorURL: String?,
        terminalTitlePrefix: String?,
        identityUpdatedAt: String?,
        editorWindowFound: Bool,
        chromeWindowFound: Bool,
        terminalWindowCount: Int,
        expectedTerminalWindowCount: Int
    ) {
        self.projectName = projectName
        self.streamName = streamName
        self.worktreePath = worktreePath
        self.editorMatchTitle = editorMatchTitle
        self.chromeAnchorURL = chromeAnchorURL
        self.terminalTitlePrefix = terminalTitlePrefix
        self.identityUpdatedAt = identityUpdatedAt
        self.editorWindowFound = editorWindowFound
        self.chromeWindowFound = chromeWindowFound
        self.terminalWindowCount = terminalWindowCount
        self.expectedTerminalWindowCount = expectedTerminalWindowCount
    }
}
