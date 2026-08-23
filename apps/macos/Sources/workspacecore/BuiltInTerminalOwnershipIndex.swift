import Foundation

/// One reconcile pass's snapshot of the rows a built-in terminal session's owner can be found in.
///
/// Resolving one session's owner walks workspaces in project-then-workspace order looking for the
/// running process, agent row, or terminal window that references it. Read per session, that is three
/// per-workspace queries for every workspace for every live session, and the foreground-agent reconcile
/// runs on every terminal runtime-state change, so the fan-out grows with projects times sessions and
/// dominates the daemon's CPU on an ordinary desktop. This index holds the same rows read by three
/// full-table queries, in the same per-workspace order, so a pass builds it once and every lookup in the
/// pass reads memory.
struct BuiltInTerminalOwnershipIndex {
    /// Workspace ids in project-then-workspace order. The ownership lookup takes the first match across
    /// workspaces, so this order is part of its result, not a presentation detail.
    let workspaceIDs: [String]
    private let runningProcessesByWorkspace: [String: [RunningProcessRecord]]
    private let agentWindowsByWorkspace: [String: [AgentWindowRecord]]
    private let windowsByWorkspace: [String: [WindowRecord]]

    init(
        workspaceIDs: [String], runningProcessesByWorkspace: [String: [RunningProcessRecord]],
        agentWindowsByWorkspace: [String: [AgentWindowRecord]], windowsByWorkspace: [String: [WindowRecord]]
    ) {
        self.workspaceIDs = workspaceIDs
        self.runningProcessesByWorkspace = runningProcessesByWorkspace
        self.agentWindowsByWorkspace = agentWindowsByWorkspace
        self.windowsByWorkspace = windowsByWorkspace
    }

    func runningProcesses(workspaceID: String) -> [RunningProcessRecord] { runningProcessesByWorkspace[workspaceID] ?? [] }

    func agentWindows(workspaceID: String) -> [AgentWindowRecord] { agentWindowsByWorkspace[workspaceID] ?? [] }

    func windows(workspaceID: String) -> [WindowRecord] { windowsByWorkspace[workspaceID] ?? [] }
}
