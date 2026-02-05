import Foundation

public struct YabaiDisplay: Decodable, Sendable {
    public let index: Int
}

public struct YabaiSpace: Decodable, Sendable {
    public let index: Int
    public let display: Int
}

public struct YabaiWindow: Decodable, Sendable {
    public let id: Int
    public let app: String
    public let title: String?
    public let space: Int
    public let display: Int
    public let isSticky: Bool
    public let isHidden: Bool
    public let isVisible: Bool
    public let isNativeFullscreen: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case app
        case title
        case space
        case display
        case isSticky = "is-sticky"
        case isHidden = "is-hidden"
        case isVisible = "is-visible"
        case isNativeFullscreen = "is-native-fullscreen"
    }
}

public struct YabaiValidation: Sendable {
    public let displayExists: Bool
    public let spaceExists: Bool
}

public final class YabaiAdapter {
    public init() {}

    public func isAvailable() -> Bool {
        (try? listSpaces()) != nil
    }

    public func listDisplays() throws -> [YabaiDisplay] {
        let json = try Shell.runAndCapture(["yabai", "-m", "query", "--displays"])
        return try decodeList(json)
    }

    public func listSpaces() throws -> [YabaiSpace] {
        let json = try Shell.runAndCapture(["yabai", "-m", "query", "--spaces"])
        return try decodeList(json)
    }

    public func listWindows(spaceIndex: Int? = nil) throws -> [YabaiWindow] {
        var command = ["yabai", "-m", "query", "--windows"]
        if let spaceIndex {
            command.append(contentsOf: ["--space", String(spaceIndex)])
        }
        let json = try Shell.runAndCapture(command)
        return try decodeList(json)
    }

    public func validate(displayIndex: Int, spaceIndex: Int) throws -> YabaiValidation {
        let displays = try listDisplays()
        let spaces = try listSpaces()
        let displayExists = displays.contains(where: { $0.index == displayIndex })
        let spaceExists = spaces.contains(where: { $0.index == spaceIndex })
        return YabaiValidation(displayExists: displayExists, spaceExists: spaceExists)
    }

    @discardableResult
    public func focusWindow(id: Int) throws -> Bool {
        do {
            _ = try Shell.runAndCapture(["yabai", "-m", "window", "--focus", String(id)])
            return true
        } catch {
            return false
        }
    }

    public func minimizeWindow(id: Int) throws {
        _ = try Shell.runAndCapture(["yabai", "-m", "window", "--minimize", String(id)])
    }

    public func closeWindow(id: Int) throws {
        _ = try Shell.runAndCapture(["yabai", "-m", "window", "--close", String(id)])
    }

    public func windowExists(id: Int) throws -> Bool {
        let windows = try listWindows()
        return windows.contains(where: { $0.id == id })
    }

    private func decodeList<T: Decodable>(_ json: String) throws -> [T] {
        let data = Data(json.utf8)
        return try JSONDecoder().decode([T].self, from: data)
    }
}
