import Foundation

public extension RunningProcessRecord {
    var terminalTrackingKey: String? {
        if terminalApp == TerminalHost.ghostty.appName, let windowID {
            return "window:\(windowID)"
        }
        if let sessionID = itermSessionID, !sessionID.isEmpty {
            return "terminal:\(sessionID)"
        }
        if let windowID {
            return "window:\(windowID)"
        }
        return nil
    }
}

public extension WindowRecord {
    var terminalTrackingKey: String? {
        if app == TerminalHost.ghostty.appName, let windowID {
            return "window:\(windowID)"
        }
        if let sessionID = itermSessionID, !sessionID.isEmpty {
            return "terminal:\(sessionID)"
        }
        if let windowID {
            return "window:\(windowID)"
        }
        return nil
    }
}
