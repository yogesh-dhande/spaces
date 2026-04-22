import Foundation
import appctl

public extension RunningProcessRecord {
    var terminalTrackingIdentity: TerminalTrackingIdentity? {
        if let tmuxWindowID, !tmuxWindowID.isEmpty {
            return .tmux(tmuxWindowID)
        }
        if let sessionID = itermSessionID, !sessionID.isEmpty {
            return .session(sessionID)
        }
        if let windowID {
            return .window(windowID)
        }
        return nil
    }

    var terminalFocusIdentity: TerminalTrackingIdentity? {
        if let sessionID = itermSessionID, !sessionID.isEmpty {
            return .session(sessionID)
        }
        if let windowID {
            return .window(windowID)
        }
        if let tmuxWindowID, !tmuxWindowID.isEmpty {
            return .tmux(tmuxWindowID)
        }
        return nil
    }

    var terminalTrackingKey: String? { terminalTrackingIdentity?.trackingKey }
}

public extension WindowRecord {
    var terminalTrackingIdentity: TerminalTrackingIdentity? {
        if let tmuxWindowID, !tmuxWindowID.isEmpty {
            return .tmux(tmuxWindowID)
        }
        if let sessionID = itermSessionID, !sessionID.isEmpty {
            return .session(sessionID)
        }
        if let windowID {
            return .window(windowID)
        }
        return nil
    }

    var terminalFocusIdentity: TerminalTrackingIdentity? {
        if let sessionID = itermSessionID, !sessionID.isEmpty {
            return .session(sessionID)
        }
        if let windowID {
            return .window(windowID)
        }
        if let tmuxWindowID, !tmuxWindowID.isEmpty {
            return .tmux(tmuxWindowID)
        }
        return nil
    }

    var terminalTrackingKey: String? { terminalTrackingIdentity?.trackingKey }
}

public extension AgentWindowRecord {
    var terminalTrackingIdentity: TerminalTrackingIdentity? {
        if let tmuxWindowID, !tmuxWindowID.isEmpty {
            return .tmux(tmuxWindowID)
        }
        if let sessionID = itermSessionID, !sessionID.isEmpty {
            return .session(sessionID)
        }
        if let windowID = yabaiWindowID ?? windowID {
            return .window(windowID)
        }
        return nil
    }

    var terminalFocusIdentity: TerminalTrackingIdentity? {
        if let sessionID = itermSessionID, !sessionID.isEmpty {
            return .session(sessionID)
        }
        if let windowID = yabaiWindowID ?? windowID {
            return .window(windowID)
        }
        if let tmuxWindowID, !tmuxWindowID.isEmpty {
            return .tmux(tmuxWindowID)
        }
        return nil
    }

    var terminalTrackingKey: String? { terminalTrackingIdentity?.trackingKey }
}
