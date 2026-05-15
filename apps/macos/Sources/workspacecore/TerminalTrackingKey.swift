import Foundation
import systembridge

extension RunningProcessRecord {
    /// Identity used to correlate runtime rows that refer to the same terminal slot.
    /// Spaces uses its session ID as the terminal identity.
    public var terminalTrackingIdentity: TerminalTrackingIdentity? {
        if let sessionID = terminalTrackingID, !sessionID.isEmpty { return .session(sessionID) }
        if let windowID { return .window(windowID) }
        return nil
    }

    /// Identity used when Spaces actively refocuses this terminal.
    public var terminalFocusIdentity: TerminalTrackingIdentity? {
        if let sessionID = terminalTrackingID, !sessionID.isEmpty { return .session(sessionID) }
        if let windowID { return .window(windowID) }
        return nil
    }

    public var terminalTrackingKey: String? { terminalTrackingIdentity?.trackingKey }
}

extension WindowRecord {
    /// Stable identity for reconciling this tracked window with process and agent rows.
    public var terminalTrackingIdentity: TerminalTrackingIdentity? {
        if let sessionID = terminalTrackingID, !sessionID.isEmpty { return .session(sessionID) }
        if let windowID { return .window(windowID) }
        return nil
    }

    /// Best-effort terminal refocus identity for this tracked window.
    public var terminalFocusIdentity: TerminalTrackingIdentity? {
        if let sessionID = terminalTrackingID, !sessionID.isEmpty { return .session(sessionID) }
        if let windowID { return .window(windowID) }
        return nil
    }

    public var terminalTrackingKey: String? { terminalTrackingIdentity?.trackingKey }
}

extension AgentWindowRecord {
    /// Identity used to associate coding-agent state with an existing tracked terminal row.
    public var terminalTrackingIdentity: TerminalTrackingIdentity? {
        if let sessionID = terminalTrackingID, !sessionID.isEmpty { return .session(sessionID) }
        if let windowID = yabaiWindowID ?? windowID { return .window(windowID) }
        return nil
    }

    /// Identity used when focusing a coding-agent row back to its terminal.
    public var terminalFocusIdentity: TerminalTrackingIdentity? {
        if let sessionID = terminalTrackingID, !sessionID.isEmpty { return .session(sessionID) }
        if let windowID = yabaiWindowID ?? windowID { return .window(windowID) }
        return nil
    }

    public var terminalTrackingKey: String? { terminalTrackingIdentity?.trackingKey }
}
