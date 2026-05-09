import Foundation

public enum IPCNotification {
    public static let agentEventFired = Notification.Name("spaces.ipc.agent-event-fired")
    public static let selectWorkspaceDetail = Notification.Name("spaces.ipc.select-workspace-detail")
    public static let openTerminalSessionWindow = Notification.Name("spaces.ipc.open-terminal-session-window")
    public static let workspaceIDUserInfoKey = "workspace_id"
    public static let terminalSessionIDUserInfoKey = "terminal_session_id"
    public static let terminalAttachmentModeUserInfoKey = "terminal_attachment_mode"
}
