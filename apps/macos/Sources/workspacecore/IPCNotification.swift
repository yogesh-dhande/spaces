import Foundation

public enum IPCNotification {
    public static let agentEventFired = Notification.Name("spaces.ipc.agent-event-fired")
    public static let selectWorkspaceDetail = Notification.Name("spaces.ipc.select-workspace-detail")
    public static let showMainWindow = Notification.Name("spaces.ipc.show-main-window")
    public static let hideMainWindow = Notification.Name("spaces.ipc.hide-main-window")
    public static let showWindowIssueModal = Notification.Name("spaces.ipc.show-window-issue-modal")
    public static let cycleWorkspaceWindow = Notification.Name("spaces.ipc.cycle-workspace-window")
    public static let openWorkspaceTerminal = Notification.Name("spaces.ipc.open-workspace-terminal")
    public static let runWorkspaceProcess = Notification.Name("spaces.ipc.run-workspace-process")
    public static let stopWorkspaceProcess = Notification.Name("spaces.ipc.stop-workspace-process")
    public static let restartWorkspaceProcess = Notification.Name("spaces.ipc.restart-workspace-process")
    public static let launchWorkspaceAgent = Notification.Name("spaces.ipc.launch-workspace-agent")
    public static let openTerminalSessionWindow = Notification.Name("spaces.ipc.open-terminal-session-window")
    public static let focusTerminalSessionWindow = Notification.Name("spaces.ipc.focus-terminal-session-window")
    public static let closeTerminalSessionWindow = Notification.Name("spaces.ipc.close-terminal-session-window")
    public static let dumpTerminalSessionWindowState = Notification.Name("spaces.ipc.dump-terminal-session-window-state")
    public static let workspaceIDUserInfoKey = "workspace_id"
    public static let workspaceTargetNameUserInfoKey = "workspace_target_name"
    public static let titleUserInfoKey = "title"
    public static let detailUserInfoKey = "detail"
    public static let cycleDirectionUserInfoKey = "cycle_direction"
    public static let terminalSessionIDUserInfoKey = "terminal_session_id"
    public static let terminalAttachmentModeUserInfoKey = "terminal_attachment_mode"
    public static let focusRequestIDUserInfoKey = "focus_request_id"
    public static let outputPathUserInfoKey = "output_path"
}
