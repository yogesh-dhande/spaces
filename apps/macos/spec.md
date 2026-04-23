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

## Key Design Decisions
- Separate window per process.
  Dedicated process windows keep each terminal focus target stable because Muxy cannot predict which terminals a user will want side by side later.
- Browser sessions are lazy bookmarks that open into dedicated Chrome windows only when focused.
  Some workspaces may carry many useful URLs, but opening all of them during launch or restart is wasteful when the user may only need a subset in a given session.
- Focus a browser session by activating its tracked Chrome window and reselecting tab `1`.
  The first tab is unlikely to be reordered by the user, while additional tabs are much more likely to be appended during normal browsing in that window.
- Launch workspace processes inside tmux.
  This lets Muxy recover the terminal view without losing the underlying process when a supported terminal-host window is closed or needs to be recreated.
- Keep workspace lifecycle separate from runtime health.
  `Running` and `Stopped` should stay easy to explain, while failed processes, failed checks, or stale tracked windows surface as warnings on top of that lifecycle state.
- Require explicit tracked-window targets for CLI-driven focus.
  Focus should not guess which window the user meant, because arbitrary focus becomes unpredictable as workspaces collect multiple windows.
  Example: one workspace may have a frontend browser, an admin browser, an API terminal, and a coding-agent terminal all open at once. If the user clicks Focus in the GUI or runs `mx workspace up --focus`, Muxy should not silently pick whichever window was captured first or happened to survive most recently. The user may want the admin browser now and the coding-agent terminal five seconds later. Requiring an explicit tracked window target keeps focus behavior deterministic. CLI focus targets should be selected by unique window names rather than numeric positions.
- Never resize or reposition tracked windows unless initiated by the user.
  Muxy should respect where the user placed each tracked window, because it cannot infer whether the user wants side-by-side windows, overlapping windows, or some other layout that includes non-Muxy windows.
- Never control windows that Muxy does not explicitly track.
  Muxy should not hide, move, resize, or otherwise manipulate unrelated windows, because the user may intentionally keep an untracked window visible next to a tracked workspace window.
- Keep coding-agent events explicit.
  `mx workspace import` and `mx workspace up` must not infer agent lifecycle, because only the agent can accurately report when it actually initialized, started active work, is waiting, is done, or exited.
- Use explicit names as the stable identity surface for focusable browser sessions, processes, and coding-agent terminals.
  Names express purpose and intent, stay meaningful when URLs or process commands change, and avoid collisions where multiple coding agents may run the same command. Those names must be unique within a workspace's combined focusable set so GUI and CLI focus can target one unambiguous window by name.

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
- browser windows for browser sessions that have been opened on demand
- coding-agent terminal windows

Muxy focuses those windows; it does not decide their geometry.

## Onboarding
- On launch, Muxy blocks only on the cheap prerequisite checks: a supported terminal host installed (`iTerm2` or `Ghostty`), tmux installed, and yabai installed.
- During first-run setup, either `iTerm2` or `Ghostty` satisfies the terminal prerequisite. If both are installed, Muxy should default the terminal host preference to `Ghostty`. If neither is installed, setup should direct the user to install `Ghostty` via Homebrew or the Ghostty website.
- The slower yabai readiness step, including service-running and Accessibility validation, should be deferred until the setup flow is actually shown or another yabai-backed action needs it.
- If a deferred yabai readiness check fails during startup, Muxy should switch into the setup flow at the yabai step instead of surfacing a raw shell error dialog.
- If a blocking launch prerequisite fails, the main window shows a guided setup flow starting at the first failing step.
- The setup flow should poll and recover automatically once the missing prerequisite is fixed.
- If all prerequisites pass, the main UI should load without an extra setup window.

## Projects
- Users can add a project from a local directory or a git URL.
- Git imports should create an app-managed clone and default workspace.
- Non-git projects should create one default workspace for the project directory.
- Project creation and deletion should show progress without freezing the UI.
- Sidebar project rows should use the leading chevron/name area to expand or collapse workspace lists.
- Sidebar project row collapsed state should persist across app restarts and sidebar refreshes.
- Sidebar project rows should expose a dedicated settings action that opens project settings in the detail pane.

## Workspaces

### Creation
- Users can create, update, focus, stop, restart, and archive workspaces from the GUI.
- The CLI should stay minimal and support `workspace import`, `workspace update`, `workspace up`, and `agent event`.
- For git projects, new workspaces are branch-oriented and should support an existing-branch picker, a new-branch entry path, target branch, directory name, title, and tooltip inputs.
- Workspace creation should feel fast in the GUI, with visible progress during setup.
- Workspace settings used for launch must remain editable after creation.

### Discovery
- Muxy should periodically discover valid git worktrees for registered projects.
- Newly discovered worktrees should become workspaces automatically.
- Invalid removed worktrees should cause non-default workspaces to archive automatically.
- Workspaces intentionally removed from Muxy should not be silently recreated by discovery.
- Sidebar git activity should remain visible while background refresh is in flight and update in place when fresh status arrives.

## Launch and Runtime Behavior
- Launch starts the workspace's configured processes and captures the resulting windows.
- Browser sessions stay configured while the workspace is running, but Muxy should leave them unopened until the user explicitly focuses that browser session.
- Unopened browser sessions should not degrade runtime health or show missing-window warnings for an otherwise running workspace.
- Workspace processes should be launched inside tmux so Muxy can recover the terminal view without losing the underlying process when a supported terminal-host window closes.
- Process commands are treated as direct executable invocations with arguments.
- If a user needs composite shell behavior such as `cd x && y`, pipes, or redirection, they should wrap it explicitly, for example `bash -lc "cd x && y"`.
- Stop shuts down tracked runtime state and closes tracked dedicated windows safely.
- Restart performs a stop followed by a fresh launch.
- `workspace up` is the idempotent "ensure running" path:
  - if stopped, it launches the workspace
  - if running, it restores failed or exited runtime as defined by the command mode
  - `--restart` forces a full restart
- `workspace update` should own post-creation workspace metadata edits such as title and tooltip.
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
- When focusing an already-open browser session, Muxy should activate Chrome and select the first tab in that tracked window.
- Terminal focus should land on the intended dedicated process or agent session.
- Focusing a tracked terminal window should flash a short semitransparent overlay on top of the target window in both iTerm2 and Ghostty.
- The focus-pulse overlay color should be configured from the GUI settings panel.
- Users should be able to choose the default terminal host globally, and both the GUI and CLI should respect that selection.
- After the GUI focuses or opens an external window, Muxy should hide itself immediately so the target app stays unobstructed.
- When a workspace detail view becomes visible, Muxy should refresh workspace windows and process state asynchronously so stale rows reconcile shortly after the page appears.
- If tracked windows become stale during next/previous window cycling, Muxy should skip them and continue to the next live target.
- Muxy should not poll in the background to verify whether a tracked browser-session window still exists; it should validate that on demand when the user focuses that browser session.
- If direct window focus from the app targets a stale browser session, Muxy should reopen that session in a new Chrome window and update tracking without showing an error modal first.
- If direct window focus from the app targets a stale process window, Muxy should first try to recover silently by opening a new dedicated window in the selected terminal host and reattaching to the existing tmux session when the process is still running. If the process is no longer running, Muxy should show a modal warning with `Recover (Cmd+R)` and `Cancel (Esc)`, and the explicit recovery action should restart it inside tmux.
  - coding-agent windows only show the error state and do not offer recovery
- Muxy should still reconcile stale tracked windows in the background instead of forcing the user to repair state manually.
- Degraded runtime health should appear as a warning on top of the current `Running` or `Stopped` lifecycle state, not as a separate replacement state label.

## Dashboard and Health
- The app should surface attention items across workspaces in one place.
- Attention includes exited processes, failed status checks, missing configured processes in running workspaces, and coding-agent states such as waiting or done.
- A stopped workspace can still contribute attention items when that helps the user notice something actionable.
- Missing configured processes in running workspaces should appear in the dashboard with the same direct recovery path offered from the Run tab.
- Dashboard attention rows should support direct window focus by click and by the numbered window shortcuts.
- The dashboard sidebar badge and dock badge should reflect the number of visible dashboard attention rows after dismissals are applied.
- Users should be able to dismiss individual dashboard attention items so they disappear from the dashboard list and dock badge until that specific attention event changes.
- Dismissing a dashboard attention item must not hide the underlying process, status check, or agent row from the workspace detail pane.

## Editing and Shortcuts
- The app should support keyboard-driven use for common actions.
- Project and workspace detail screens should prefer flat section layouts with spacing and dividers over nested bordered cards.
- Global shortcuts should bring Muxy forward and support fast workspace switching.
- The global app-toggle shortcut should hide Muxy when it is already frontmost and visible, and show it otherwise.
- Summoning Muxy from the global app-toggle shortcut should raise the main window above other apps and onto the active space.
- When Muxy is summoned, it should select the workspace for the window that was focused immediately before activation when that window belongs to a tracked workspace; otherwise it should keep the previously selected workspace.
- The app should expose a configurable shortcut leader that supplies the shared modifiers for leader-based shortcuts like workspace navigation, dashboard, editor, Finder, and queued window focus.
- Window rows in the selected workspace should expose numbered shortcuts for direct focus.
- Workspace Run-tab rows and their numbered focus shortcuts should keep the saved workspace-settings order for configured browser sessions and processes, and append newly added ad-hoc windows after those configured rows.
- Browser-session rows should stay visible in the Run tab even when the workspace is stopped so the user can still open them directly.
- Process rows in the Run tab should stay visible for configured processes that are currently missing so the user still has a direct recovery path.
- Focusing a missing configured process should show the same `Recover (Cmd+R)` or `Cancel (Esc)` modal used for stale tracked process windows, and a successful recovery should reuse that configured process row instead of creating a duplicate row.
- Run-tab rows should show the tracked window or process name as the primary label and the target detail, such as a browser URL or process command, as secondary text.
- Ad-hoc terminal rows should keep their generated focus name as the primary label and use the live terminal window title as secondary text.
- CLI-driven focus through `mx workspace up --focus` should require an explicit tracked window target instead of picking an arbitrary window.
- CLI focus should use unique names across focusable browser sessions, processes, and coding-agent terminals, and `mx workspace up --focus` should require one of those names explicitly.
- Configured workspace processes and browser sessions must always have explicit names; Muxy should reject unnamed entries instead of falling back to commands or URLs as identities.
- Focus target discovery may remain GUI-centric; the CLI does not need a separate read-only discovery command.
- Window-number shortcuts should use a configurable direct-focus modifier plus digits `1` through `9`.
- Window-number sequence shortcuts should use a separate configurable modifier plus digits `1` through `9`, then replay the queued focus actions in order when the modifiers are released.
- Shortcut handling must not break normal text-edit shortcuts while an input is focused.
- Recovery affordances should reserve `Cmd+R`; app-data reload should default to leader+`R` so it stays distinct from recovery modals.
- Dashboard should default to leader+`G` so it does not conflict with the macOS Dock toggle shortcut.
- Every keyboard shortcut the product supports must be configurable from the GUI settings panel.

## Coding-Agent Integration
- Coding agents can explicitly report lifecycle events through `mx agent event`.
- Agent events are not implied by `workspace import` or `workspace up`.
- `mx agent event` should support explicit `init`, `start`, `waiting`, `done`, and `exit` events.
- Agent events from unsupported terminal hosts should be dropped instead of recorded. Coding agents run from tmux are not supported by Muxy and should return an explicit error instead of being inferred onto workspace process terminals.
- `init` should identify the originating terminal and either attach to an already tracked terminal row or create a tracked terminal row for that coding agent.
- Terminal identity should be adapter-driven and consistent across supported hosts: prefer tmux window identity when present, otherwise prefer a stable session/token identity, and only fall back to a yabai window identity when no durable session-like identity exists.
- iTerm2 should use `ITERM_SESSION_ID` as both its hook identity and its durable native terminal identity when available.
- Ghostty agent tracking should keep two separate identities: a Muxy-issued terminal tracking token for CLI hook attribution and the real Ghostty terminal ID for focus, liveness, and retab rebinding.
- Ghostty agent events without a Muxy-issued tracking token should be dropped instead of being rebound to whichever Ghostty tab or window happens to be frontmost.
- Ghostty focus may fall back from `terminalNativeID` to the stored hook token only when resolving an already tracked terminal row in the same workspace; it must not guess from the frontmost Ghostty tab/window.
- Coding-agent rows should render after browser and process rows so non-agent shortcut ordering stays stable when agents appear or disappear.
- `start` should show a spinner, `waiting` should show a warning indicator and count toward dashboard and dock attention, and `done` should remain in dashboard and dock attention until dismissed while still rendering as a green dot on the workspace row. `idle` should render as a gray dot without creating dashboard attention.
- `exit` should return the row to idle when the terminal is still open; if the terminal is closed, ad-hoc agent rows should be removed immediately, including when background runtime refresh detects the terminal closure after the fact, while rows linked to workspace process terminals should remain idle.

## Errors and Feedback
- Long-running actions should show visible progress.
- Failure states should be explicit and actionable.
- The GUI should prefer inline guidance over silent failure or hidden background behavior.
- Background sidebar/runtime refresh should update in place without replacing the current detail pane or resetting the selected workspace tab.

## Update Experience
- The app should check for updates periodically and allow manual update checks.
- When an update is available, the user should be able to install it from within the app.
- `mx --version` should report the current version.
