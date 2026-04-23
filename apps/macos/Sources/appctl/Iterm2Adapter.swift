import Foundation

open class Iterm2Adapter: @unchecked Sendable {
    private let scheduleVerificationWork: @Sendable (@escaping @Sendable () -> Void) -> Void

    public init() {
        self.scheduleVerificationWork = { work in
            Task.detached(priority: .utility) { work() }
        }
    }

    public init(scheduleVerificationWork: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        self.scheduleVerificationWork = scheduleVerificationWork
    }

    open func isAvailable() -> Bool { (try? AppleScript.run("tell application \"iTerm2\" to version")) != nil }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    open func openWindowAndRun(command: String, background: Bool = false) throws -> ItermWindowInfo {
        let escaped = appleScriptEscaped(command)
        let activateLine = background ? "" : "activate"
        let script = """
            tell application "iTerm2"
              \(activateLine)
              set newWindow to (create window with default profile)
              tell current session of newWindow
                write text "\(escaped)"
              end tell
              -- Newly created iTerm2 windows start with a single tab, so tab index is deterministically 1.
              return (id of newWindow as string) & "|" & (id of current session of newWindow as string) & "|1"
            end tell
            """
        let output = try AppleScript.run(script)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let windowID = Int(parts.first ?? trimmed) ?? -1
        let sessionID = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        let tabIndex = parts.count > 2 ? Int(parts[2]) : nil
        return ItermWindowInfo(id: windowID, sessionID: sessionID, tabIndex: tabIndex)
    }

    open func openTabInWindowAndRun(windowID: Int, command: String, background: Bool = false) throws -> ItermWindowInfo {
        let escaped = appleScriptEscaped(command)
        let activateLine = background ? "" : "activate"
        let script = """
            tell application "iTerm2"
              \(activateLine)
              repeat with w in windows
                if id of w is \(windowID) then
                  tell w
                    create tab with default profile
                    tell current session
                      write text "\(escaped)"
                    end tell
                    set tabCounter to 0
                    repeat with t in tabs
                      set tabCounter to tabCounter + 1
                      if t is current tab then
                        return (id of w as string) & "|" & (id of current session as string) & "|" & (tabCounter as string)
                      end if
                    end repeat
                    return (id of w as string) & "|" & (id of current session as string) & "|"
                  end tell
                end if
              end repeat
              return ""
            end tell
            """
        let output = try AppleScript.run(script)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "muxy.iterm2", code: 1, userInfo: [NSLocalizedDescriptionKey: "iTerm2 window \(windowID) not found"])
        }
        let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let resolvedWindowID = Int(parts.first ?? trimmed) ?? windowID
        let sessionID = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        let tabIndex = parts.count > 2 ? Int(parts[2]) : nil
        return ItermWindowInfo(id: resolvedWindowID, sessionID: sessionID, tabIndex: tabIndex)
    }

    open func runInWindow(id: Int, command: String) throws {
        let escaped = appleScriptEscaped(command)
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

    open func closeWindow(id: Int) throws {
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

    open func closeSessionOrTab(preferredSessionID: String?, tabIndex: Int?, windowID: Int?) throws -> Bool {
        let escapedSessionID = appleScriptEscaped(preferredSessionID ?? "")
        let targetTabIndex = tabIndex ?? -1
        let targetWindowID = windowID ?? -1
        let script = """
            tell application "iTerm2"
              set targetSessionID to "\(escapedSessionID)"
              set targetTabIndex to \(targetTabIndex)
              set targetWindowID to \(targetWindowID)

              if targetSessionID is not "" then
                repeat with w in windows
                  repeat with t in tabs of w
                    repeat with s in sessions of t
                      if (id of s as string) is targetSessionID then
                        -- Do not select window/tab before close: `tell w to select`
                        -- reorders the window list and invalidates the index-based
                        -- s reference, causing the wrong session to be closed.
                        try
                          close s
                        on error
                          return ""
                        end try
                        return "session"
                      end if
                    end repeat
                  end repeat
                end repeat
                return ""
              end if

              if targetWindowID > 0 then
                repeat with w in windows
                  if id of w is targetWindowID then
                    if targetTabIndex > 0 then
                      set tabCounter to 0
                      repeat with t in tabs of w
                        set tabCounter to tabCounter + 1
                        if tabCounter is targetTabIndex then
                          if (count of tabs of w) > 1 then
                            close t
                            return "tab"
                          end if
                          close w
                          return "window"
                        end if
                      end repeat
                    end if
                    close w
                    return "window"
                  end if
                end repeat
              end if

              return ""
            end tell
            """
        let output = try AppleScript.run(script)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Pulses the background color of the given iTerm2 window to `pulseColor` (0–255 per channel) and back.
    open func pulseBackground(windowID: Int, pulseColor: (r: Int, g: Int, b: Int)) throws {
        // iTerm2 AppleScript uses 16-bit color values (0–65535); convert from 8-bit.
        let r = pulseColor.r * 257
        let g = pulseColor.g * 257
        let b = pulseColor.b * 257
        let script = """
            tell application "iTerm2"
              repeat with w in windows
                if id of w is \(windowID) then
                  tell current session of w
                    set c to background color
                    set background color to {\(r), \(g), \(b)}
                    delay 0.3
                    set background color to c
                  end tell
                  exit repeat
                end if
              end repeat
            end tell
            """
        _ = try? AppleScript.run(script)
    }

    open func backgroundColor(windowID: Int) throws -> (r: Int, g: Int, b: Int)? {
        let script = """
            tell application "iTerm2"
              repeat with w in windows
                if id of w is \(windowID) then
                  tell current session of w
                    set c to background color
                    return (item 1 of c as string) & "," & (item 2 of c as string) & "," & (item 3 of c as string)
                  end tell
                end if
              end repeat
              return ""
            end tell
            """
        let output = try AppleScript.run(script).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }
        let parts = output.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 3,
            let red16 = Int(parts[0]),
            let green16 = Int(parts[1]),
            let blue16 = Int(parts[2])
        else {
            return nil
        }
        return (r: red16 / 257, g: green16 / 257, b: blue16 / 257)
    }

    @discardableResult
    open func setBackgroundColor(windowID: Int, color: (r: Int, g: Int, b: Int)) throws -> Bool {
        let r = color.r * 257
        let g = color.g * 257
        let b = color.b * 257
        let script = """
            tell application "iTerm2"
              repeat with w in windows
                if id of w is \(windowID) then
                  tell current session of w
                    set background color to {\(r), \(g), \(b)}
                  end tell
                  return "1"
                end if
              end repeat
              return ""
            end tell
            """
        let output = try AppleScript.run(script).trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
    }

    open func listSessionIDs() throws -> Set<String> {
        let script = """
            tell application "iTerm2"
              set sessionIDs to {}
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    set end of sessionIDs to (id of s as string)
                  end repeat
                end repeat
              end repeat
              set AppleScript's text item delimiters to "\n"
              return sessionIDs as string
            end tell
            """
        let output = try AppleScript.run(script)
        let ids = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Set(ids)
    }

    open func focusedSessionID(windowID: Int?) throws -> String? {
        let targetWindowID = windowID ?? -1
        let script = """
            tell application "iTerm2"
              set targetWindowID to \(targetWindowID)

              if targetWindowID > 0 then
                repeat with w in windows
                  if id of w is targetWindowID then
                    return (id of current session of w as string)
                  end if
                end repeat
                return ""
              end if

              try
                return (id of current session of current window as string)
              on error
                return ""
              end try
            end tell
            """
        let output = try AppleScript.run(script)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    open func focusSessionOrTab(preferredSessionID: String?, tabIndex: Int?, windowID: Int?) throws -> Bool {
        let escapedSessionID = (preferredSessionID ?? "").replacingOccurrences(of: "\"", with: "\\\"")
        let targetTabIndex = tabIndex ?? -1
        let targetWindowID = windowID ?? -1
        let script = """
            tell application "iTerm2"
              set targetSessionID to "\(escapedSessionID)"
              set targetTabIndex to \(targetTabIndex)
              set targetWindowID to \(targetWindowID)

              if targetSessionID is not "" then
                repeat with w in windows
                  repeat with t in tabs of w
                    repeat with s in sessions of t
                      if (id of s as string) is targetSessionID then
                        activate
                        tell w to select
                        select t
                        tell s to select
                        return "session"
                      end if
                    end repeat
                  end repeat
                end repeat
              end if

              if targetWindowID > 0 then
                repeat with w in windows
                  if id of w is targetWindowID then
                    if targetTabIndex > 0 then
                      set tabCounter to 0
                      repeat with t in tabs of w
                        set tabCounter to tabCounter + 1
                        if tabCounter is targetTabIndex then
                          set current window to w
                          select t
                          tell w to select
                          activate
                          return "tab"
                        end if
                      end repeat
                    end if
                    set current window to w
                    tell w to select
                    activate
                    return "window"
                  end if
                end repeat
              end if

              return ""
            end tell
            """
        let output = try AppleScript.run(script)
        let result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return false }
        if result == "session", let preferredSessionID, !preferredSessionID.isEmpty {
            scheduleSessionFocusVerification(preferredSessionID: preferredSessionID, windowID: windowID)
        }
        return true
    }

    open func scheduleSessionFocusVerification(preferredSessionID: String, windowID: Int?) {
        scheduleVerificationWork { [weak self] in
            guard let self else { return }
            do {
                let verified = try self.verifyFocusedSession(preferredSessionID: preferredSessionID, windowID: windowID)
                if !verified {
                    self.logFocusVerification(
                        "session_verification_failed session_id=\(preferredSessionID) window_id=\(windowID ?? -1)"
                    )
                }
            } catch {
                self.logFocusVerification(
                    "session_verification_error session_id=\(preferredSessionID) window_id=\(windowID ?? -1) error=\(error.localizedDescription)"
                )
            }
        }
    }

    open func verifyFocusedSession(preferredSessionID: String, windowID: Int?) throws -> Bool {
        let escapedSessionID = appleScriptEscaped(preferredSessionID)
        let targetWindowID = windowID ?? -1
        let script = """
            tell application "iTerm2"
              set targetSessionID to "\(escapedSessionID)"
              set targetWindowID to \(targetWindowID)

              repeat with w in windows
                if targetWindowID < 0 or id of w is targetWindowID then
                  repeat 10 times
                    if (id of current session of w as string) is targetSessionID then
                      return "session"
                    end if
                    delay 0.05
                  end repeat
                  return ""
                end if
              end repeat

              return ""
            end tell
            """
        let output = try AppleScript.run(script)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func logFocusVerification(_ message: String) {
        guard ProcessInfo.processInfo.environment["DEBUG"] == "1" else { return }
        fputs("muxy: iterm \(message)\n", stderr)
    }
}

extension Iterm2Adapter: TerminalAdapter {
    public var appName: String { "iTerm2" }
    public var bundleIdentifier: String { "com.googlecode.iterm2" }

    private func commandApplyingEnvironment(_ command: String, environment: [String: String]) -> String {
        guard !environment.isEmpty else { return command }
        let exports = environment
            .sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(shellQuoted($0.value))" }
            .joined(separator: "; ")
        return "\(exports); \(command)"
    }

    private func shellQuoted(_ token: String) -> String {
        "'\(token.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func commandApplyingWorkingDirectory(_ command: String, cwd: String) -> String {
        let trimmedDirectory = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDirectory.isEmpty else { return command }
        return "cd \(shellQuoted(trimmedDirectory)) && \(command)"
    }

    public func openWindowAndRun(command: String, cwd: String, environment: [String: String], background: Bool) throws -> TerminalLaunchResult {
        let launchedCommand = commandApplyingWorkingDirectory(
            commandApplyingEnvironment(command, environment: environment),
            cwd: cwd)
        let window = try openWindowAndRun(command: launchedCommand, background: background)
        return TerminalLaunchResult(
            trackingIdentity: window.sessionID.map(TerminalTrackingIdentity.session) ?? .window(window.id),
            hookSessionID: window.sessionID,
            containerID: String(window.id),
            fallbackWindowID: window.id,
            tabIndex: window.tabIndex)
    }

    public func resolveCurrentTrackingIdentity(environment: [String: String], yabaiFocusedWindowID: Int?) throws -> TerminalTrackingIdentity? {
        guard let raw = environment["ITERM_SESSION_ID"], !raw.isEmpty else {
            return yabaiFocusedWindowID.map(TerminalTrackingIdentity.window)
        }
        guard let colonIndex = raw.lastIndex(of: ":") else {
            return .session(raw)
        }
        return .session(String(raw[raw.index(after: colonIndex)...]))
    }

    public func focusTrackedTerminal(_ target: TerminalFocusTarget) throws -> Bool {
        let sessionID: String?
        let windowID: Int?
        switch target.trackingIdentity {
        case .session(let id):
            sessionID = id
            windowID = target.windowID
        case .window(let id):
            sessionID = nil
            windowID = id
        case .tmux, nil:
            sessionID = nil
            windowID = target.windowID
        }
        return try focusSessionOrTab(preferredSessionID: sessionID, tabIndex: target.tabIndex, windowID: windowID)
    }

    public func listLiveTrackingIdentities() throws -> Set<TerminalTrackingIdentity> {
        Set(try listSessionIDs().map(TerminalTrackingIdentity.session))
    }
}
