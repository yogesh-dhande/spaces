import Foundation

public enum IPCNotification {
    public static let agentEventFired = Notification.Name("muxy.ipc.agent-event-fired")
    public static let selectWorkspaceDetail = Notification.Name("muxy.ipc.select-workspace-detail")
    public static let workspaceIDUserInfoKey = "workspace_id"
}
