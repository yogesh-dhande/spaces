import Foundation

public enum Tile: String, Codable, Sendable {
    case leftHalf
    case rightHalf
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

public struct WindowLayout: Codable, Sendable {
    public let displayIndex: Int
    public let tile: Tile

    public init(displayIndex: Int, tile: Tile) {
        self.displayIndex = displayIndex
        self.tile = tile
    }
}

public struct WindowTarget: Sendable {
    public let bundleID: String
    public let matchTitle: String?
    public let preferFocusedWindow: Bool

    public init(bundleID: String, matchTitle: String? = nil, preferFocusedWindow: Bool = true) {
        self.bundleID = bundleID
        self.matchTitle = matchTitle
        self.preferFocusedWindow = preferFocusedWindow
    }
}

public struct MoveOptions: Sendable {
    public let retries: Int
    public let delayMs: Int
    public let postFullscreenDelayMs: Int
    public let exitFullscreen: Bool
    public let unminimize: Bool

    public init(
        retries: Int = 25,
        delayMs: Int = 80,
        postFullscreenDelayMs: Int = 300,
        exitFullscreen: Bool = true,
        unminimize: Bool = true
    ) {
        self.retries = retries
        self.delayMs = delayMs
        self.postFullscreenDelayMs = postFullscreenDelayMs
        self.exitFullscreen = exitFullscreen
        self.unminimize = unminimize
    }
}

public struct WindowInfo: Sendable {
    public let title: String
    public let isFullscreen: Bool

    public init(title: String, isFullscreen: Bool) {
        self.title = title
        self.isFullscreen = isFullscreen
    }
}

public struct WindowList: Sendable {
    public let bundleID: String
    public let appName: String
    public let windows: [WindowInfo]
    public let focusedWindow: WindowInfo?

    public init(bundleID: String, appName: String, windows: [WindowInfo], focusedWindow: WindowInfo?) {
        self.bundleID = bundleID
        self.appName = appName
        self.windows = windows
        self.focusedWindow = focusedWindow
    }
}

public enum WinmoveError: LocalizedError, Sendable {
    case accessibilityPermissionMissing
    case appNotRunning(bundleID: String)
    case invalidDisplayIndex(index: Int, screenCount: Int)
    case windowNotFound(bundleID: String)
    case moveFailed(bundleID: String)

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "Accessibility permission is missing. Enable Terminal and agentmux in System Settings > Privacy & Security > Accessibility."
        case let .appNotRunning(bundleID):
            return "App not running for bundle id: \(bundleID)"
        case let .invalidDisplayIndex(index, screenCount):
            return "Invalid display index \(index). Detected screens: \(screenCount)"
        case let .windowNotFound(bundleID):
            return "Window not found after retries for bundle id: \(bundleID)"
        case let .moveFailed(bundleID):
            return "Failed to move window after retries for bundle id: \(bundleID)"
        }
    }
}
