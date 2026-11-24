import Foundation

/// A named, step-by-step procedure the MCP server hands to any connected agent: through the
/// `instructions` index in the `initialize` result and, in full, through the `spaces_workflow` tool.
/// Tools and instructions are the delivery mechanism because every agent Spaces supports reads both,
/// which is not true of MCP prompts or skill files.
enum MCPWorkflow: String, CaseIterable {
    case handoff, dispatch, standup, unblock

    /// One line of what the workflow is for and when to reach for it. Feeds the `instructions` index and
    /// the `spaces_workflow` tool description, so a model can choose a workflow without fetching any text.
    var purpose: String {
        switch self {
        case .handoff:
            "continue this conversation's work in a fresh coding agent session (for example \"hand this off to Codex\"); also when stale context is degrading this session"
        case .dispatch:
            "run a new, self-contained task in a separate agent in its own workspace and branch, possibly on another device, or several tasks in parallel"
        case .standup: "report what the user's coding agents are doing and which are working, blocked, or done (read-only)"
        case .unblock: "get blocked or waiting agents moving by answering mechanical prompts and bringing real questions back to the user"
        }
    }

    /// The full steps, returned verbatim by `spaces_workflow`.
    var steps: String {
        switch self {
        case .handoff: Self.handoffSteps
        case .dispatch: Self.dispatchSteps
        case .standup: Self.standupSteps
        case .unblock: Self.unblockSteps
        }
    }

    /// Index served in the `initialize` result. Claude Code truncates server instructions past 4096
    /// characters, so this lists only what each workflow is for and where the steps come from.
    static var instructions: String {
        let index = allCases.map { "- \($0.rawValue): \($0.purpose)." }.joined(separator: "\n")
        return """
            Spaces runs coding agents (Claude Code, Codex, opencode, Copilot CLI, pi, Amp) in their own workspaces and branches, on this machine or paired devices. Spaces workflows: before you hand off work, start another agent, report on agents, or unblock one, call spaces_workflow with the workflow name and follow the steps it returns.

            \(index)

            Do not improvise these from the tool list alone: the workflows carry rules the individual tools do not (spawn an agent once, never grant hook trust, confirm pickup before reporting success).
            """
    }
}
