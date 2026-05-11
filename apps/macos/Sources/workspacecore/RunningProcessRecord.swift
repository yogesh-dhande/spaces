import Foundation

public struct RunningProcessRecord: Codable, Sendable {
    public let id: String
    public let workspaceID: String
    public let templateName: String
    public let command: String
    public let runtimeTargetID: String?
    public let terminalTarget: TerminalTargetRecord?
    public let pid: Int?
    public let status: RunningProcessState
    public let logPath: String?
    public let lastOutputAt: String?
    public let startedAt: String?
    public let exitedAt: String?

    public init(
        id: String, workspaceID: String, templateName: String, command: String, runtimeTargetID: String? = nil,
        terminalTarget: TerminalTargetRecord? = nil, pid: Int?, status: RunningProcessState, logPath: String?, lastOutputAt: String?,
        startedAt: String?, exitedAt: String?
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.templateName = templateName
        self.command = command
        self.runtimeTargetID = runtimeTargetID
        self.terminalTarget = terminalTarget
        self.pid = pid
        self.status = status
        self.logPath = logPath
        self.lastOutputAt = lastOutputAt
        self.startedAt = startedAt
        self.exitedAt = exitedAt
    }

    public init(
        id: String, workspaceID: String, templateName: String, command: String, runtimeTargetID: String? = nil, terminalApp: String?, windowID: Int?,
        terminalTrackingID: String? = nil, terminalNativeID: String? = nil, terminalContainerID: String? = nil, itermTabIndex: Int? = nil,
        tmuxWindowID: String? = nil, pid: Int?, status: RunningProcessState, logPath: String?, lastOutputAt: String?, startedAt: String?,
        exitedAt: String?
    ) {
        let terminalTarget: TerminalTargetRecord? =
            if terminalApp != nil || windowID != nil || terminalTrackingID != nil || terminalNativeID != nil || terminalContainerID != nil
                || itermTabIndex != nil || tmuxWindowID != nil
            {
                TerminalTargetRecord(
                    app: terminalApp ?? "", windowID: windowID, trackingID: terminalTrackingID, nativeID: terminalNativeID,
                    containerID: terminalContainerID, itermTabIndex: itermTabIndex, tmuxWindowID: tmuxWindowID)
            } else { nil }
        self.init(
            id: id, workspaceID: workspaceID, templateName: templateName, command: command, runtimeTargetID: runtimeTargetID,
            terminalTarget: terminalTarget, pid: pid, status: status, logPath: logPath, lastOutputAt: lastOutputAt, startedAt: startedAt,
            exitedAt: exitedAt)
    }

    public init(
        id: String, workspaceID: String, templateName: String, command: String, terminalApp: String?, windowID: Int?,
        terminalTrackingID: String? = nil, terminalNativeID: String? = nil, terminalContainerID: String? = nil, itermTabIndex: Int? = nil,
        tmuxWindowID: String? = nil, pid: Int?, status: RunningProcessState, logPath: String?, lastOutputAt: String?, startedAt: String?,
        exitedAt: String?
    ) {
        self.init(
            id: id, workspaceID: workspaceID, templateName: templateName, command: command, runtimeTargetID: nil, terminalApp: terminalApp,
            windowID: windowID, terminalTrackingID: terminalTrackingID, terminalNativeID: terminalNativeID, terminalContainerID: terminalContainerID,
            itermTabIndex: itermTabIndex, tmuxWindowID: tmuxWindowID, pid: pid, status: status, logPath: logPath, lastOutputAt: lastOutputAt,
            startedAt: startedAt, exitedAt: exitedAt)
    }

    public var terminalApp: String? { terminalTarget?.app }
    public var windowID: Int? { terminalTarget?.windowID }
    public var terminalTrackingID: String? { terminalTarget?.trackingID }
    public var terminalNativeID: String? { terminalTarget?.nativeID }
    public var terminalContainerID: String? { terminalTarget?.containerID }
    public var itermTabIndex: Int? { terminalTarget?.itermTabIndex }
    public var tmuxWindowID: String? { terminalTarget?.tmuxWindowID }
}
