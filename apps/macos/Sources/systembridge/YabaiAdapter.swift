import Foundation

public final class YabaiAdapter {
    public init() {}

    public func isAvailable() -> Bool { (try? listSpaces()) != nil }

    public func listDisplays() throws -> [YabaiDisplay] {
        let json = try Shell.runAndCapture(command(["-m", "query", "--displays"]))
        return try decodeList(json)
    }

    public func listSpaces() throws -> [YabaiSpace] {
        let json = try Shell.runAndCapture(command(["-m", "query", "--spaces"]))
        return try decodeList(json)
    }

    public func listWindows(spaceIndex: Int? = nil) throws -> [YabaiWindow] {
        var arguments = ["-m", "query", "--windows"]
        if let spaceIndex { arguments.append(contentsOf: ["--space", String(spaceIndex)]) }
        let json = try Shell.runAndCapture(command(arguments))
        return try decodeList(json)
    }

    public func focusedWindow() throws -> YabaiWindow? {
        let startedAt = Date()
        do {
            let jsonStartedAt = Date()
            let json = try Shell.runAndCapture(command(["-m", "query", "--windows", "--window"]))
            let decodeStartedAt = Date()
            let window: YabaiWindow = try decodeObject(json)
            logFocusedWindowDebug(
                stage: "success", elapsedMS: elapsedMS(since: startedAt),
                detail:
                    "shell_ms=\(elapsedMS(since: jsonStartedAt)) decode_ms=\(elapsedMS(since: decodeStartedAt)) window_id=\(window.id) app=\(sanitizeDebugValue(window.app))"
            )
            return window
        } catch {
            logFocusedWindowDebug(
                stage: "failure", elapsedMS: elapsedMS(since: startedAt), detail: "error=\(sanitizeDebugValue(error.localizedDescription))")
            return nil
        }
    }

    public func window(id: Int) throws -> YabaiWindow? {
        do {
            let json = try Shell.runAndCapture(command(["-m", "query", "--windows", "--window", String(id)]))
            return try decodeObject(json)
        } catch { return nil }
    }

    @discardableResult public func focusWindow(id: Int) throws -> Bool {
        let startedAt = Date()
        do {
            let succeeded = try Shell.run(command(["-m", "window", "--focus", String(id)])) == 0
            logFocusWindowDebug(stage: "success", elapsedMS: elapsedMS(since: startedAt), detail: "window_id=\(id) success=\(succeeded ? 1 : 0)")
            return succeeded
        } catch {
            logFocusWindowDebug(
                stage: "failure", elapsedMS: elapsedMS(since: startedAt),
                detail: "window_id=\(id) error=\(sanitizeDebugValue(error.localizedDescription))")
            return false
        }
    }

    public func closeWindow(id: Int) throws { _ = try Shell.run(command(["-m", "window", "--close", String(id)])) }

    private func decodeList<T: Decodable>(_ json: String) throws -> [T] {
        let data = Data(json.utf8)
        return try JSONDecoder().decode([T].self, from: data)
    }

    private func decodeObject<T: Decodable>(_ json: String) throws -> T {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func command(_ arguments: [String]) throws -> [String] {
        guard let executablePath = ExecutableLocator.resolve(.yabai) else {
            throw NSError(domain: "spaces.yabai", code: 127, userInfo: [NSLocalizedDescriptionKey: "yabai executable not found"])
        }
        return [executablePath] + arguments
    }

    private func logFocusedWindowDebug(stage: String, elapsedMS: Int, detail: String) {
        guard ProcessInfo.processInfo.environment["DEBUG"] == "1" else { return }
        fputs("spaces: yabai_focused_window stage=\(stage) elapsed_ms=\(elapsedMS) \(detail)\n", stderr)
    }

    private func logFocusWindowDebug(stage: String, elapsedMS: Int, detail: String) {
        guard ProcessInfo.processInfo.environment["DEBUG"] == "1" else { return }
        fputs("spaces: yabai_focus_window stage=\(stage) elapsed_ms=\(elapsedMS) \(detail)\n", stderr)
    }

    private func elapsedMS(since start: Date) -> Int { max(Int(Date().timeIntervalSince(start) * 1000), 0) }

    private func sanitizeDebugValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
    }
}
