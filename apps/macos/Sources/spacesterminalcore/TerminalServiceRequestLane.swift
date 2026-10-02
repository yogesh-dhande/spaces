/// Which serial worker queue of `TerminalServiceServer` runs a request.
///
/// A request that can run for minutes (a git clone, or a workspace create, start, stop or restart that runs
/// git and the project's setup script) gets a lane of its own, so it never holds up the unrelated requests
/// that share `shared`: agent hook signals, the MCP event drain, other CLI calls, and the Mac app's park
/// before Stop All and Quit.
///
/// Each lane is serial. Workspace lifecycle commands queue behind one another because two of them can name
/// the same workspace, or create worktrees in the same project repository, and git and the setup script are
/// not safe to run twice at once there. A project create shares no state with them (it opens its own store
/// connection and imports into a fresh directory), so it does not queue behind a workspace command, and
/// they do not queue behind a multi-minute clone.
enum TerminalServiceRequestLane {
    case shared
    case projectCreate
    case workspaceLifecycle

    init(_ command: TerminalServiceCommand) {
        guard case .profileCommand(let profileCommand) = command else {
            self = .shared
            return
        }
        switch profileCommand {
        case .projectCreate: self = .projectCreate
        case .workspaceCreate, .workspaceStart, .workspaceStop, .workspaceRestart: self = .workspaceLifecycle
        default: self = .shared
        }
    }
}
