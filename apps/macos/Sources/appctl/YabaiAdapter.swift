import Foundation

public final class YabaiAdapter {
    public init() {}

    public func isAvailable() -> Bool { (try? listSpaces()) != nil }

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
        if let spaceIndex { command.append(contentsOf: ["--space", String(spaceIndex)]) }
        let json = try Shell.runAndCapture(command)
        return try decodeList(json)
    }

    public func focusedWindow() throws -> YabaiWindow? {
        do {
            let json = try Shell.runAndCapture(["yabai", "-m", "query", "--windows", "--window"])
            return try decodeObject(json)
        } catch { return nil }
    }

    public func window(id: Int) throws -> YabaiWindow? {
        do {
            let json = try Shell.runAndCapture(["yabai", "-m", "query", "--windows", "--window", String(id)])
            return try decodeObject(json)
        } catch { return nil }
    }

    @discardableResult public func focusWindow(id: Int) throws -> Bool {
        do {
            return try Shell.run(["yabai", "-m", "window", "--focus", String(id)]) == 0
        } catch { return false }
    }

    public func closeWindow(id: Int) throws { _ = try Shell.run(["yabai", "-m", "window", "--close", String(id)]) }

    private func decodeList<T: Decodable>(_ json: String) throws -> [T] {
        let data = Data(json.utf8)
        return try JSONDecoder().decode([T].self, from: data)
    }

    private func decodeObject<T: Decodable>(_ json: String) throws -> T {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
