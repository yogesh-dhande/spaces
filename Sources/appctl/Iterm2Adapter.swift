import Foundation

public struct ItermWindowInfo: Sendable {
    public let id: Int
}

public final class Iterm2Adapter {
    public init() {}

    public func isAvailable() -> Bool {
        (try? AppleScript.run("tell application \"iTerm2\" to version")) != nil
    }

    public func openWindowAndRun(command: String) throws -> ItermWindowInfo {
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "iTerm2"
          activate
          set newWindow to (create window with default profile)
          tell current session of newWindow
            write text "\(escaped)"
          end tell
          return id of newWindow
        end tell
        """
        let output = try AppleScript.run(script)
        return ItermWindowInfo(id: Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1)
    }

    public func runInWindow(id: Int, command: String) throws {
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            if id of w is \(id) then
              tell current session of w
                write text "\(escaped)"
              end tell
            end if
          end repeat
        end tell
        """
        _ = try AppleScript.run(script)
    }

    public func closeWindow(id: Int) throws {
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            if id of w is \(id) then
              close w
            end if
          end repeat
        end tell
        """
        _ = try AppleScript.run(script)
    }
}
