import Foundation
import spacesterminalcore

public enum IPCNotification {
    public static let agentEventFired = Notification.Name("spaces.ipc.agent-event-fired")
    public static let selectWorkspaceDetail = Notification.Name("spaces.ipc.select-workspace-detail")
    public static let showMainWindow = Notification.Name("spaces.ipc.show-main-window")
    public static let hideMainWindow = Notification.Name("spaces.ipc.hide-main-window")
    public static let showWindowIssueModal = Notification.Name("spaces.ipc.show-window-issue-modal")
    public static let cycleWorkspaceWindow = Notification.Name("spaces.ipc.cycle-workspace-window")
    /// Focus a workspace's focusable window by its display name (browser session, process,
    /// or agent), driving the same client-side focus path the numbered shortcuts use.
    /// Carries `workspaceIDUserInfoKey` and `workspaceTargetNameUserInfoKey`.
    public static let focusWorkspaceWindowByName = Notification.Name("spaces.ipc.focus-workspace-window-by-name")
    /// Focus a workspace's running process window. Carries `workspaceIDUserInfoKey`,
    /// `workspaceTargetNameUserInfoKey` (the process template name), and optional
    /// `focusRequestIDUserInfoKey` for terminal-focus follow-through correlation.
    public static let focusWorkspaceProcess = Notification.Name("spaces.ipc.focus-workspace-process")
    /// Ask the app to write the workspace's ordered focusable window names as
    /// `{"names": [...]}` to `outputPathUserInfoKey`. Carries `workspaceIDUserInfoKey`.
    /// The app owns the ordering, so harnesses read it from the app rather than recomputing.
    public static let dumpFocusableWindowNames = Notification.Name("spaces.ipc.dump-focusable-window-names")
    public static let openWorkspaceTerminal = Notification.Name("spaces.ipc.open-workspace-terminal")
    public static let runWorkspaceProcess = Notification.Name("spaces.ipc.run-workspace-process")
    public static let stopWorkspaceProcess = Notification.Name("spaces.ipc.stop-workspace-process")
    public static let restartWorkspaceProcess = Notification.Name("spaces.ipc.restart-workspace-process")
    public static let launchWorkspaceAgent = Notification.Name("spaces.ipc.launch-workspace-agent")
    public static let openTerminalSessionWindow = Notification.Name("spaces.ipc.open-terminal-session-window")
    public static let focusTerminalSessionWindow = Notification.Name("spaces.ipc.focus-terminal-session-window")
    public static let closeTerminalSessionWindow = Notification.Name("spaces.ipc.close-terminal-session-window")
    public static let dumpTerminalSessionWindowState = Notification.Name("spaces.ipc.dump-terminal-session-window-state")
    public static let performTerminalSessionWindowShortcut = Notification.Name("spaces.ipc.perform-terminal-session-window-shortcut")
    /// Posted by any process after it commits a database write, so the app can
    /// reload sidebar metadata from external CLI/daemon edits without polling or
    /// watching database files.
    public static let databaseDidChange = Notification.Name("spaces.ipc.database-did-change")
    /// Posted by the macOS client after changing client-owned Caddy route registry entries, so the
    /// local daemon can reload Caddy without treating the registry as daemon database state.
    public static let caddyRouteRegistryDidChange = Notification.Name("spaces.ipc.caddy-route-registry-did-change")
    /// Posted by the daemon to ask the client to show an OS notification, because a
    /// bundle-less daemon cannot post one itself. Carries `titleUserInfoKey`,
    /// `detailUserInfoKey` (body), and optional `notificationSubtitleUserInfoKey`.
    public static let deliverUserNotification = Notification.Name("spaces.ipc.deliver-user-notification")
    public static let workspaceIDUserInfoKey = "workspace_id"
    public static let workspaceTargetNameUserInfoKey = "workspace_target_name"
    public static let titleUserInfoKey = "title"
    public static let detailUserInfoKey = "detail"
    public static let notificationSubtitleUserInfoKey = "notification_subtitle"
    public static let cycleDirectionUserInfoKey = "cycle_direction"
    public static let terminalSessionIDUserInfoKey = "terminal_session_id"
    public static let terminalAttachmentModeUserInfoKey = "terminal_attachment_mode"
    public static let terminalSessionIsTerminatingUserInfoKey = "terminal_session_is_terminating"
    public static let focusRequestIDUserInfoKey = "focus_request_id"
    public static let outputPathUserInfoKey = "output_path"
    public static let terminalShortcutActionUserInfoKey = "terminal_shortcut_action"
    public static let terminalShortcutTextUserInfoKey = "terminal_shortcut_text"

    public static func currentObject() throws -> String { try SpacesProfile.current().ipcNotificationObject }

    public static func post(_ name: Notification.Name, userInfo: [String: String]? = nil, profile: SpacesProfile? = nil) throws {
        #if os(macOS)
            let resolvedProfile = try profile ?? SpacesProfile.current()
            DistributedNotificationCenter.default().postNotificationName(
                name, object: resolvedProfile.ipcNotificationObject, userInfo: userInfo, options: [.deliverImmediately])
        #else
            throw NSError(
                domain: "dev.usespaces.ipc", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Spaces app IPC notifications are only available on macOS."])
        #endif
    }
}
