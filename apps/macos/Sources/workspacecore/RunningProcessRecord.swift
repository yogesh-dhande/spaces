import Foundation

public struct RunningProcessRecord: Codable, Sendable {
    public let id: String
    public let workspaceID: String
    public let templateID: String?
    public let templateName: String
    public let command: String
    public let runtimeTargetID: String?
    public let terminalApp: String?
    public let terminalTarget: TerminalTargetRecord?
    public let pid: Int?
    public let status: RunningProcessState
    public let logPath: String?
    public let lastOutputAt: String?
    public let startedAt: String?
    public let exitedAt: String?

    public init(
        id: String, workspaceID: String, templateID: String? = nil, templateName: String, command: String, runtimeTargetID: String? = nil,
        terminalApp: String? = nil, terminalTarget: TerminalTargetRecord? = nil, pid: Int?, status: RunningProcessState, logPath: String?,
        lastOutputAt: String?, startedAt: String?, exitedAt: String?
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.templateID = templateID
        self.templateName = templateName
        self.command = command
        self.runtimeTargetID = runtimeTargetID
        self.terminalApp = terminalApp
        self.terminalTarget = terminalTarget
        self.pid = pid
        self.status = status
        self.logPath = logPath
        self.lastOutputAt = lastOutputAt
        self.startedAt = startedAt
        self.exitedAt = exitedAt
    }

    public init(
        id: String, workspaceID: String, templateID: String? = nil, templateName: String, command: String, runtimeTargetID: String? = nil,
        terminalApp: String?, windowID: Int?, terminalTrackingID: String? = nil, terminalNativeID: String? = nil, pid: Int?,
        status: RunningProcessState, logPath: String?, lastOutputAt: String?, startedAt: String?, exitedAt: String?
    ) {
        let resolvedTrackingID = terminalTrackingID ?? terminalNativeID
        let terminalTarget: TerminalTargetRecord? =
            if windowID != nil || resolvedTrackingID != nil {
                TerminalTargetRecord(runtimeTargetID: runtimeTargetID, windowID: windowID, trackingID: resolvedTrackingID)
            } else { nil }
        self.init(
            id: id, workspaceID: workspaceID, templateID: templateID, templateName: templateName, command: command, runtimeTargetID: runtimeTargetID,
            terminalApp: terminalApp, terminalTarget: terminalTarget, pid: pid, status: status, logPath: logPath, lastOutputAt: lastOutputAt,
            startedAt: startedAt, exitedAt: exitedAt)
    }

    public init(
        id: String, workspaceID: String, templateID: String? = nil, templateName: String, command: String, terminalApp: String?, windowID: Int?,
        terminalTrackingID: String? = nil, terminalNativeID: String? = nil, pid: Int?, status: RunningProcessState, logPath: String?,
        lastOutputAt: String?, startedAt: String?, exitedAt: String?
    ) {
        self.init(
            id: id, workspaceID: workspaceID, templateID: templateID, templateName: templateName, command: command, runtimeTargetID: nil,
            terminalApp: terminalApp, windowID: windowID, terminalTrackingID: terminalTrackingID, terminalNativeID: terminalNativeID, pid: pid,
            status: status, logPath: logPath, lastOutputAt: lastOutputAt, startedAt: startedAt, exitedAt: exitedAt)
    }

    public var windowID: Int? { terminalTarget?.windowID }
    public var terminalTrackingID: String? { terminalTarget?.trackingID }
    public var terminalNativeID: String? { terminalTarget?.trackingID }
}
