import Foundation
import spacesterminalcore

/// The step-by-step text of each `MCPWorkflow`. Swift literals rather than SwiftPM resources because the
/// `spaces` CLI also ships on Linux as a single binary with no resource bundle. Tool and field names here
/// must match the tools in `SpacesMCPServer.swift`; the unit tests check every `spaces_*` name mentioned
/// against the tool list.
extension MCPWorkflow {
    static let handoffSteps = #"""
        # Handoff

        Write a handoff document summarising the current conversation so a fresh agent can continue the work, then use the Spaces tools to spawn that agent and point it at the document.

        If the conversation holds no task or context worth continuing, say so and stop. Do not start an agent.

        ## 1. Write the handoff document

        Save it to the temporary directory of the user's OS, not the current workspace. If you cannot write files (for example, in a chat app), keep the document in hand and send its full text as the prompt in step 2 instead of a path.

        - Include a "suggested skills" section in the document, naming skills the agent should invoke.
        - Do not duplicate content already captured in other artifacts (specs, plans, ADRs, issues, commits, diffs). Reference them by path or URL instead.
        - Redact sensitive information such as API keys, passwords, or personally identifiable information.
        - If the user said what the next session will be used for, tailor the document to that.

        ## 2. Spawn the successor agent

        Where the successor runs: if you are working inside a Spaces workspace, spawn it there. Otherwise (for example, in a chat app) use the project the user named. Ask if they named none; never pick one yourself. Then create a fresh workspace with `spaces_workspace_create` (`project`, a short kebab-case `branch`) and `spaces_workspace_start`, and spawn in it.

        1. Call `spaces_agent_spawn` with `command` set to the agent CLI the user asked for (\#(CodingAgent.commandListText)), else the same agent CLI you are running as (default to `claude` if unsure), plus `workspace` when you created one. Spawn delivers no prompt; it only starts the agent and returns an `agentSpawn` object with `terminalSessionID`. Spawn once: if it times out or reports the agent not ready, read that session with `spaces_terminal_tail` and handle the dialog there. Never spawn a second agent.
        2. Send the handoff prompt with `spaces_terminal_send`:
           - `session`: `agentSpawn.terminalSessionID`
           - `text`: a short prompt such as `Read <absolute path to handoff doc> and continue the work described there.`, or the full handoff document when there is no file
           - `submit`: true (one call is enough; submit-safety is server-side)
        3. Confirm the agent picked the work up: poll `spaces_agent_status` or `spaces_terminal_tail` for the session, and report success only once the tail shows it working on the handoff. `spaces_agent_status` fails until the agent has emitted its first hook signal, so rely on the tail until then. If a folder trust or onboarding dialog appears, answer it with `spaces_terminal_send` (an empty `text` with `submit: true` presses Enter alone) and re-send the handoff if the dialog swallowed it. Never grant trust to hooks or tools that run outside the sandbox: pick the option that continues without trusting and tell the user.
        4. If `agentSpawn.subscribed` is false, call `spaces_agent_subscribe` on `agentSpawn.terminalSessionID` once the agent has signaled (it fails before then, so retry) so blocked and done notifications flow back. This needs you to be running inside a Spaces terminal; otherwise skip it.

        Finish by telling the user the handoff document path (if you saved one) and the `agentSpawn.open` deep link to the new terminal.
        """#

    static let dispatchSteps = #"""
        # Dispatch

        Dispatch a task to a new agent in its own Spaces workspace.

        ## 1. Resolve the target

        - Device: default to this machine. If the user named a paired device, resolve it with `spaces_device_list` first and pass `device` on every call below, the project lookup included: a paired device has its own projects.
        - Project: call `spaces_project_list` (with `device` for a paired device) and use the project the user named. If they named none, use the project containing the current directory, but only when you are working inside one on this machine. Otherwise ask which project; never pick one yourself.
        - Branch: derive a short kebab-case branch name from the task unless the user gave one. Set `existingBranch: true` only when the user asked to reuse a branch.

        ## 2. Create and start the workspace

        1. `spaces_workspace_create` with `project` and `branch` (plus `baseBranch` or `device` when given). For a git project this creates a worktree on the new branch and runs project setup. The workspace is created but NOT started.
        2. `spaces_workspace_start` with the new workspace's ID (from `spaces_workspace_create`'s result, or `spaces_workspace_list` if the result carries none, as it does on a paired device).

        ## 3. Spawn the agent and hand it the task

        1. `spaces_agent_spawn` with the agent CLI command (\#(CodingAgent.commandListText); default `claude`) and the new `workspace` ID. `workspace` is required when spawning on a paired device. Spawn delivers no prompt and returns an `agentSpawn` object with `terminalSessionID`. Spawn once per task: if it times out or reports the agent not ready, a dialog is usually blocking it. Read that session with `spaces_terminal_tail` and handle the dialog there (step 3). Never spawn a second agent for the same task.
        2. Send the task with `spaces_terminal_send`: `session` = `agentSpawn.terminalSessionID`, `text` = the task prompt, `submit: true`. Write the prompt so it stands alone: the new agent has none of this conversation's context.
        3. Handle startup dialogs, read with `spaces_terminal_tail`:
           - Folder trust or onboarding for the new workspace: answer it with `spaces_terminal_send` (empty `text` with `submit: true` presses Enter alone).
           - A request to trust hooks, tools, or anything that runs outside the sandbox: never grant it. Pick the option that continues without trusting (arrow keys via `bytes`, e.g. `27, 91, 66` is Down, then an empty submit), and tell the user it was skipped.
           - Re-send the task if a dialog swallowed it.
        4. Confirm pickup: report success only after `spaces_terminal_tail` shows the agent working on the task, not a dialog and not an empty prompt. If it is still stuck, say exactly what is on screen.
        5. If `agentSpawn.subscribed` is false, call `spaces_agent_subscribe` on `agentSpawn.terminalSessionID` after the agent emits its first hook signal (it fails before then, so retry) so blocked and done notifications flow back. This needs you to be running inside a Spaces terminal; otherwise skip it.

        Finish by telling the user the workspace branch and directory and the `agentSpawn.open` deep link to the new terminal.
        """#

    static let standupSteps = #"""
        # Standup

        Give the user a status roll-up of their agents. Read-only: never send input to a terminal in this workflow.

        ## Gather

        1. `spaces_device_list` to enumerate paired devices.
        2. `spaces_agent_list` for this machine and for each reachable paired device (pass `device`). Each row has `label`, `status`, `briefSummary` (the first line of the agent's brief), `projectName`, `workspaceName`, `branch`, `deviceID` (set for a paired device), and `open` (the `spaces://terminal` deep link).
        3. For any agent whose status or `briefSummary` leaves its situation unclear, especially blocked ones, read `spaces_terminal_tail` (`lines`: 30-40, with `device` for a paired device) on its `terminalSessionID` to see what it is actually doing or asking. Skip the tail for agents whose row already tells the story.

        ## Report

        Order by urgency: agents needing attention first (blocked, waiting on a dialog or question), then actively working, then done or exited.

        For each agent give: label, project and workspace and branch, device (when not this machine), one line on what it is doing or stuck on (from its `briefSummary` or the tail), and its `open` deep link. For blocked agents, quote the actual question or dialog from the tail so the user can decide without opening the terminal.

        Close with a one-line headline: how many working, blocked, and done. If nothing is running anywhere, say exactly that.
        """#

    static let unblockSteps = #"""
        # Unblock

        Get blocked agents moving again. Pairs well with a recurring loop for babysitting a fleet.

        ## 1. Find blocked agents

        `spaces_device_list`, then `spaces_agent_list` for this machine and each reachable device (pass `device`). If the user limited the scope (a project, workspace, or device), consider only agents inside it and leave every other agent untouched. For every agent that is blocked or waiting, read `spaces_terminal_tail` (`lines`: 40) to see the exact prompt on screen.

        ## 2. Decide: answer or escalate

        Auto-answer ONLY mechanical prompts where every sane user gives the same answer:

        - first-run trust, onboarding, or telemetry dialogs
        - "press Enter to continue" and pager prompts
        - resuming after a benign informational notice

        NEVER auto-answer. Always surface to the user instead:

        - destructive or hard-to-reverse confirmations (delete, overwrite, force-push, publish, deploy)
        - credential, auth, or payment prompts
        - requests to trust hooks, tools, or anything that runs outside the sandbox
        - design decisions, plan approvals, or any open question the agent asked
        - anything ambiguous: when unsure, escalate

        ## 3. Answer mechanical prompts

        Use `spaces_terminal_send` on the agent's `terminalSessionID` (with `device` for a paired device):

        - empty `text` with `submit: true` presses Enter alone
        - `text` plus `submit: true` types and submits a line
        - for TUI menus that need arrow keys, send `bytes` (e.g. `27, 91, 66` is Down arrow), then an empty submit

        Re-read `spaces_terminal_tail` after each answer to confirm the agent resumed. Call `spaces_agent_subscribe` on its session if you are not already watching it (this needs you to be running inside a Spaces terminal; otherwise skip it).

        ## 4. Report

        List what was unblocked and how. For every escalated agent, quote the question or dialog verbatim with its `open` deep link so the user can answer directly. Never answer a judgment call on the user's behalf, and never relay an answer the user has not actually given.
        """#
}
