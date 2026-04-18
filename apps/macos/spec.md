# Muxy Spec

This document defines how Muxy should behave from the user's point of view. It is the source of truth for UX and product semantics, not implementation details.

## Product Intent
Muxy is a local macOS control plane for switching between coding contexts quickly.

It should reduce the overhead of:
- creating and cleaning up workspaces and worktrees
- starting the right processes with the right ports and environment
- reopening the right browser and terminal windows
- switching focus to the right window set
- noticing attention items such as failed processes, failed checks, or coding agents waiting on a human

Muxy provides a desktop app and a CLI for power users and coding agents.

## Non-Goals
- Muxy does not manage window geometry or tiling. It simply focuses windows as laid out by the user.
- Muxy does not restore exact browser tab ordering.
- Muxy does not inspect editor internals.
- Muxy does not manage secrets beyond environment variables needed for the app to function.
- Muxy only supports the browser and terminal integrations it explicitly implements.

## Core Concepts

### Project
A project is a codebase plus reusable templates:
- setup and stop scripts
- named port definitions
- process templates
- status checks
- browser sessions

Users configure a project once, then derive workspaces from it.

### Workspace
A workspace is an isolated stream of work for one project.

A workspace has:
- a directory
- a title
- optional tooltip text
- an optional git branch
- per-workspace overrides for launch-time settings
- a captured set of windows and runtime state

Workspaces can be active or inactive in the sidebar, and can be running or stopped independently of that sidebar state.
Running and stopped should be easy to explain:
- `Running` means Muxy explicitly launched the workspace or another explicit workspace action marked it running.
- `Stopped` means Muxy has not explicitly launched it, or Muxy explicitly stopped it.
- Stale runtime leftovers should not silently change `Stopped` back to `Running`; they should surface as warnings on top of the existing lifecycle state.

### Window Set
A workspace owns a tracked set of dedicated windows, such as:
- process terminals
- browser windows for browser sessions
- coding-agent terminal windows

Muxy focuses those windows; it does not decide their geometry.

## Onboarding
- On launch, Muxy checks prerequisites in order: iTerm2 installed, tmux installed, yabai installed, yabai running, and required Accessibility access.
- If any prerequisite fails, the main window shows a guided setup flow starting at the first failing step.
- The setup flow should poll and recover automatically once the missing prerequisite is fixed.
- If all prerequisites pass, the main UI should load without an extra setup window.

## Projects
- Users can add a project from a local directory or a git URL.
- Git imports should create an app-managed clone and default workspace.
- Non-git projects should create one default workspace for the project directory.
- Project creation and deletion should show progress without freezing the UI.

## Workspaces

### Creation
- Users can create, import, update, launch, stop, restart, focus, and archive workspaces from the GUI and CLI.
- For git projects, new workspaces are branch-oriented and should support explicit branch, target branch, directory name, title, and tooltip inputs.
- Workspace creation should feel fast in the GUI, with visible progress during setup.
- Workspace settings used for launch must remain editable after creation.

### Discovery
- Muxy should periodically discover valid git worktrees for registered projects.
- Newly discovered worktrees should become workspaces automatically.
- Invalid removed worktrees should cause non-default workspaces to archive automatically.
- Workspaces intentionally removed from Muxy should not be silently recreated by discovery.

## Launch and Runtime Behavior
- Launch starts the workspace's configured processes and browser sessions and captures the resulting windows.
- Workspace processes should be launched inside tmux so Muxy can recover the terminal view without losing the underlying process when an iTerm2 window closes.
- Stop shuts down tracked runtime state and closes tracked dedicated windows safely.
- Restart performs a stop followed by a fresh launch.
- `workspace up` is the idempotent "ensure running" path:
  - if stopped, it launches the workspace
  - if running, it restores failed or exited runtime as defined by the command mode
  - `--force-restart` forces a full restart
- Launch should wait for setup to finish and should surface setup failures clearly.
- Named ports must be available to setup scripts, stop scripts, process commands, and status checks.
- Stopping or restarting a workspace must never close unrelated user windows.
- Runtime health is separate from lifecycle state:
  - `Running` workspaces can be healthy or degraded
  - `Stopped` workspaces can still have stale tracked runtime leftovers that need cleanup or recovery

## Window Management and Focus
- Workspaces map to captured window sets managed through yabai.
- Muxy should focus the correct window or workspace quickly, even when switching across apps.
- Browser focus should match the intended browser session by URL, not by window title.
- Terminal focus should land on the intended dedicated process or agent session.
- If tracked windows become stale during next/previous window cycling, Muxy should skip them and continue to the next live target.
- If direct window focus from the app targets a stale browser session or process window, Muxy should show a non-modal error and offer recovery:
  - browser sessions reopen in a new Chrome window and update tracking
  - processes recover in a new dedicated iTerm2 window by reattaching to the tmux session when still running, or by restarting inside tmux when not running
  - coding-agent windows only show the error state and do not offer recovery
- Muxy should still reconcile stale tracked windows in the background instead of forcing the user to repair state manually.
- Degraded runtime health should appear as a warning on top of the current `Running` or `Stopped` lifecycle state, not as a separate replacement state label.

## Dashboard and Health
- The app should surface attention items across workspaces in one place.
- Attention includes exited processes, failed status checks, and coding-agent states such as waiting or done.
- A stopped workspace can still contribute attention items when that helps the user notice something actionable.

## Editing and Shortcuts
- The app should support keyboard-driven use for common actions.
- Global shortcuts should bring Muxy forward and support fast workspace switching.
- Window rows in the selected workspace should expose numbered shortcuts for direct focus.
- Shortcut handling must not break normal text-edit shortcuts while an input is focused.
- Users can override configurable shortcuts where the product exposes that behavior.

## Coding-Agent Integration
- Coding agents can explicitly report lifecycle events through `mx agent event`.
- Agent events are not implied by `workspace import` or `workspace up`.
- Agent windows should appear as tracked workspace windows with visible status.
- Waiting and done states should surface in dashboard attention views.

## Errors and Feedback
- Long-running actions should show visible progress.
- Failure states should be explicit and actionable.
- The GUI should prefer inline guidance over silent failure or hidden background behavior.

## Update Experience
- The app should check for updates periodically and allow manual update checks.
- When an update is available, the user should be able to install it from within the app.
- `mx --version` should report the current version.
