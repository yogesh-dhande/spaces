import Foundation

public enum IPCNotification {
    public static let showTooltipOverlay = Notification.Name("muxy.ipc.show-tooltip-overlay")
    public static let agentHookFired = Notification.Name("muxy.ipc.agent-hook-fired")
}
