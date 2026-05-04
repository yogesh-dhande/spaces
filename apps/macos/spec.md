# Spaces Spec

This document defines how Spaces should behave from the user's point of view. It is the source of truth for UX and product semantics, not implementation details.

## Product Intent
Spaces is a local macOS control plane for switching between coding contexts quickly.

It should reduce the overhead of:
- creating and cleaning up workspaces and worktrees
- starting the right processes with the right ports and environment
- reopening the right browser and terminal windows
- switching focus to the right window set
- noticing attention items such as failed processes or coding agents waiting on a human

Spaces provides a desktop app and a CLI for power users and coding agents.

## Non-Goals
- Spaces does not manage window geometry or tiling. It simply focuses windows as laid out by the user.
- Spaces does not restore exact browser tab ordering.
- Spaces does not inspect editor internals.
- Spaces does not manage secrets beyond environment variables needed for the app to function.
- Spaces only supports the browser and terminal integrations it explicitly implements.

## Key Design Decisions
- Separate window per process.
  Dedicated process windows keep each terminal focus target stable because Spaces cannot predict which terminals a user will want side by side later.
- Browser sessions are lazy bookmarks that open into dedicated Chrome windows only when focused.
  Some workspaces may carry many useful URLs, but opening all of them during launch or restart is wasteful when the user may only need a subset in a given session.
- Focus a browser session by activating its tracked Chrome window and reselecting tab `1`.
  The first tab is unlikely to be reordered by the user, while additional tabs are much more likely to be appended during normal browsing in that window.
- Launch workspace processes inside tmux.
  This lets Spaces recover the terminal view without losing the underlying process when a supported terminal-host window is closed or needs to be recreated.
- Keep workspace lifecycle separate from runtime health.
  `Running` and `Stopped` should stay easy to explain, while failed processes or stale tracked windows surface as warnings on top of that lifecycle state.
- Require explicit tracked-window targets for CLI-driven focus.
  Focus should not guess which window the user meant, because arbitrary focus becomes unpredictable as workspaces collect multiple windows.
  Example: one workspace may have a frontend browser, an admin browser, an API terminal, and a coding-agent terminal all open at once. If the user clicks Focus in the GUI or runs `spaces open <name>`, Spaces should not silently pick whichever window was captured first or happened to survive most recently. The user may want the admin browser now and the coding-agent terminal five seconds later. Requiring an explicit tracked window target keeps focus behavior deterministic. CLI focus targets should be selected by unique window names rather than numeric positions.
- Never resize or reposition tracked windows unless initiated by the user.
  Spaces should respect where the user placed each tracked window, because it cannot infer whether the user wants side-by-side windows, overlapping windows, or some other layout that includes non-Spaces windows.
- Never control windows that Spaces does not explicitly track.
  Spaces should not hide, move, resize, or otherwise manipulate unrelated windows, because the user may intentionally keep an untracked window visible next to a tracked workspace window.
- Keep coding-agent events explicit.
  `spaces import`, `spaces start`, and `spaces restart` must not infer agent lifecycle, because only the agent can accurately report when it actually initialized, started active work, is waiting, is done, or exited.
- Use explicit names as the stable identity surface for focusable browser sessions, processes, and coding-agent terminals.
  Names express purpose and intent, stay meaningful when URLs or process commands change, and avoid collisions where multiple coding agents may run the same command. Those names must be unique within a workspace's combined focusable set so GUI and CLI focus can target one unambiguous window by name.

## Core Concepts

### Project
A project is a codebase plus reusable templates:
- setup and stop scripts
- named port definitions
- process templates
- browser sessions

Users configure a project once, then derive workspaces from it.

### Workspace
A workspace is an isolated stream of work for one project.

A workspace has:
- a directory
- a title
- optional notes text
- an optional git branch
- per-workspace overrides for launch-time settings
- a captured set of windows and runtime state

Workspaces can be visible or hidden in the sidebar, and can be running or stopped independently of that sidebar state.
Hidden workspaces live in a collapsed `Hidden` section at the bottom of the sidebar.
Running and stopped should be easy to explain:
- `Running` means Spaces explicitly launched the workspace or another explicit workspace action marked it running.
- `Stopped` means Spaces has not explicitly launched it, or Spaces explicitly stopped it.
- Stale runtime leftovers should not silently change `Stopped` back to `Running`; they should surface as warnings on top of the existing lifecycle state.

### Window Set
A workspace owns a tracked set of dedicated windows, such as:
- process terminals
- browser windows for browser sessions that have been opened on demand
- coding-agent terminal windows

Spaces focuses those windows; it does not decide their geometry.

## Onboarding
- On launch, the main window should immediately show a neutral loading state while Spaces checks prerequisites and loads workspace data, so startup never presents a blank window.
- On launch, Spaces blocks only on the cheap prerequisite checks: a supported terminal host installed (`iTerm2` or `Ghostty`), tmux installed, and yabai installed.
- Startup prerequisite checks may enrich command lookup from the user's login-shell PATH, but that lookup must stay bounded and fall back automatically to the inherited PATH plus standard package-manager locations so shell startup files cannot stall app launch indefinitely.
- When command lookup is enriched from the login-shell PATH, the app's inherited `PATH` remains authoritative. Login-shell entries should only fill gaps that are missing from the launch environment, and built-in package-manager fallbacks should remain last.
- During first-run setup, either `iTerm2` or `Ghostty` satisfies the terminal prerequisite. If both are installed, Spaces should default the terminal host preference to `Ghostty`. If neither is installed, setup should direct the user to install `Ghostty` via Homebrew or the Ghostty website.
- The slower yabai readiness step, including service-running and Accessibility validation, should be deferred until the setup flow is actually shown or another yabai-backed action needs it.
- If a deferred yabai readiness check fails during startup, Spaces should switch into the setup flow at the yabai step instead of surfacing a raw shell error dialog.
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
- The project settings pane should use the same flat detail-header treatment as workspace detail: project title and directory path at the top, then project-level configuration sections and footer actions.
- Sidebar workspace rows show the workspace title on the first line and the git branch name on a second indented line underneath; the branch line is omitted when the workspace has no branch recorded.
- The workspace detail pane is a single scrollable page: title + actions at the top, directory path with copy and reveal-in-Finder buttons, inline notes editor, then configuration sections for Processes, Browser sessions, Coding agents, Named ports, and Stop script. Each section shows its configured items as rows and expands inline into an edit form when the pencil icon is clicked; the `+ add` header button appends a new item. Running process rows should expose stop and restart actions before edit and delete, while non-running process rows should show run before edit and delete. Named-port rows should show the reserved port number as secondary text next to the configured name. A `⋯` overflow button in the action row exposes Copy path and Reveal in Finder, with Reveal in Finder available as a keyboard-invokable menu item via `⌘⇧F`.
- The workspace detail footer should show inline shortcut hints for Toggle app, Alerts, Settings, Open editor, New terminal, Next window, and Prev window, in that order.

## Workspaces

### Creation
- Users can create, update, focus, stop, restart, and archive workspaces from the GUI.
- The CLI should stay minimal and support `import`, `update`, `start`, `restart`, `open`, and `signal`.
- For git projects, new workspaces are branch-oriented and should support an existing-branch picker, a new-branch entry path, target branch, directory name, title, and notes inputs.
- Workspace creation should feel fast in the GUI, with visible progress during setup.
- Workspace settings used for launch must remain editable after creation.

### Discovery
- Spaces should periodically discover valid git worktrees for registered projects.
- Newly discovered worktrees should become workspaces automatically.
- Invalid removed worktrees should cause non-default workspaces to archive automatically.
- Workspaces intentionally removed from Spaces should not be silently recreated by discovery.

## Launch and Runtime Behavior
- Launch starts the workspace's configured processes and captures the resulting windows.
- Browser sessions stay configured while the workspace is running, but Spaces should leave them unopened until the user explicitly focuses that browser session.
- Unopened browser sessions should not degrade runtime health or show missing-window warnings for an otherwise running workspace.
- Workspace processes should be launched inside tmux so Spaces can recover the terminal view without losing the underlying process when a supported terminal-host window closes.
- tmux-backed workspace and session management must treat workspace titles, tmux window names, and tmux session names as user-controlled text that may contain visible separator-like substrings without breaking window creation, listing, or focus recovery.
- Editing workspace settings while a workspace is already running must not start or stop browser sessions or coding agents as part of save-time reconciliation. Process name and on-exit edits should update tracked running processes immediately, while command edits should require explicit confirmation to restart the affected running processes; canceling that prompt should leave the existing process configuration unchanged. New configured rows should appear immediately with their non-running status so the user can decide what to open or recover.
- Process commands support two execution modes: `Direct` runs an executable with arguments, while `Shell` runs the command through the app-wide shell setting.
- Direct mode is the recommended deterministic path for plain executable commands such as `scripts/swiftpm.sh build`.
- Direct mode also supports deterministic interpolation of Spaces-provided environment variables such as named ports and `SPACES_*` paths inside executable arguments and leading env assignments, for example `PORT=$PORT1 npm run dev`.
- Direct mode accepts only simple Spaces variable references such as `$PORT1` or `${PORT1}`. Other shell expansions such as `${PORT1:-3000}`, `$$`, or `$?` must be rejected and require Shell mode instead.
- Shell mode supports composite shell behavior such as `cd x && y`, pipes, redirection, and shell expansion.
- The global shell choice for shell-mode processes is configurable in Settings and through `spaces config process-shell`; the default is `zsh`.
- The project and workspace editors validate process commands when they are saved. Direct mode rejects shell-only syntax, while Shell mode requires only a non-empty command.
- Stop shuts down tracked runtime state and closes tracked dedicated windows safely.
- Restart performs a stop followed by a fresh launch.
- `start` is the idempotent "ensure running" path:
  - if stopped, it launches the workspace
  - if running, it restores failed or exited runtime as defined by the command mode
- `restart` forces a full restart
- `update` should own post-creation workspace metadata edits such as title and notes.
- Launch should wait for setup to finish and should surface setup failures clearly.
- Named ports must be available to setup scripts, stop scripts, and process commands.
- Adding a named port from the workspace detail view should reserve its port number immediately instead of waiting for the next workspace launch.
- Named port assignments belong to the workspace until that workspace is archived. Stopping a workspace must not give its assigned port numbers back to other workspaces.
- When a stopped workspace owns named ports, Spaces may hold placeholder reservations for those ports, but launching the workspace must hand those ports to the real process command so user-facing servers can bind them normally.
- Stopping or restarting a workspace must never close unrelated user windows.
- Runtime health is separate from lifecycle state:
  - `Running` workspaces can be healthy or degraded
  - `Stopped` workspaces can still have stale tracked runtime leftovers that need cleanup or recovery

## Window Management and Focus
- Workspaces map to captured window sets managed through yabai.
- Spaces should focus the correct window or workspace quickly, even when switching across apps.
- Browser focus should match the intended browser session by URL, not by window title.
- When focusing an already-open browser session, Spaces should activate Chrome and select the first tab in that tracked window.
- Terminal focus should land on the intended dedicated process or agent session.
- Focusing a tracked terminal window should flash a short semitransparent overlay on top of the target window in both iTerm2 and Ghostty.
- When iTerm2 session targeting needs extra verification, Spaces should still pulse as soon as the tracked terminal window is focused instead of waiting on the slower session-verification path.
- The focus-pulse overlay color should be configured from the GUI settings panel.
- Users should be able to choose the default terminal host globally, and both the GUI and CLI should respect that selection.
- After the GUI focuses or opens an external window, Spaces should hide itself immediately so the target app stays unobstructed.
- When a workspace detail view becomes visible, Spaces should refresh workspace windows and process state asynchronously so stale rows reconcile shortly after the page appears.
- If tracked windows become stale during next/previous window cycling, Spaces should skip them and continue to the next live target.
- Spaces should not poll in the background to verify whether a tracked browser-session window still exists; it should validate that on demand when the user focuses that browser session.
- If direct window focus from the app targets a stale browser session, Spaces should reopen that session in a new Chrome window and update tracking without showing an error modal first.
- If direct window focus from the app targets a stale process window, Spaces should first try to recover silently by opening a new dedicated window in the selected terminal host and reattaching to the existing tmux session when the process is still running. If the process is no longer running, Spaces should show a modal warning with `Recover (Cmd+R)` and `Cancel (Esc)`, and the explicit recovery action should restart it inside tmux.
  - coding-agent windows only show the error state and do not offer recovery
- Spaces should still reconcile stale tracked windows in the background instead of forcing the user to repair state manually.
- Degraded runtime health should appear as a warning on top of the current `Running` or `Stopped` lifecycle state, not as a separate replacement state label.

## Alerts and Health
- The app should surface attention items across workspaces in one place.
- Attention includes exited processes, missing configured processes in running workspaces, and coding-agent states such as waiting or done.
- A stopped workspace can still contribute attention items when that helps the user notice something actionable.
- Missing configured processes in running workspaces should appear in Alerts with the same direct recovery path offered from the Run tab.
- Alerts rows should support direct window focus by click and by the numbered window shortcuts.
- The Alerts sidebar badge and dock badge should reflect the number of visible Alerts attention rows after dismissals are applied.
- Users should be able to dismiss individual Alerts attention items so they disappear from the Alerts list and dock badge until that specific attention event changes.
- Dismissing an Alerts attention item must not hide the underlying process or agent row from the workspace detail pane.

## Editing and Shortcuts
- The app should support keyboard-driven use for common actions.
- Project and workspace detail screens should prefer flat section layouts with spacing and dividers over nested bordered cards.
- Global shortcuts should bring Spaces forward and support fast workspace switching.
- The global app-toggle shortcut should hide Spaces when it is already frontmost and visible, and show it otherwise.
- The app should expose a separate global command-palette shortcut that opens a lightweight palette without changing the visibility of the main window.
- The command palette should default to `Cmd+Opt+-`.
- Summoning Spaces from the global app-toggle shortcut should raise the main window above other apps and onto the active space.
- When Spaces is summoned, it should select the workspace for the window that was focused immediately before activation when that window belongs to a tracked workspace; otherwise it should show Alerts.
- The app should expose a configurable shortcut leader that supplies the shared modifiers for leader-based shortcuts like workspace navigation, Alerts, editor, terminal, and Finder.
- The command palette should draw from every navigable workspace target that can appear in workspace detail rows: browser sessions, processes, ad-hoc windows, configured coding-agent launchers, and live coding-agent terminals.
- When the command palette opens with an empty query, it should show Alerts attention items first and then the most recently focused targets across workspaces, capped to the first nine visible rows. If there is no recent focus history, it should fall back to the existing workspace-target order.
- Command-palette rows should show the same status language used by workspace detail rows, including process state and coding-agent state.
- Once the user types a query, command-palette search should fuzzy-match across all workspaces using workspace title, target name, and secondary detail text, including compact cross-field queries such as `fu` matching `Frontend` plus `URL`.
- The first command-palette result should stay selected by default, arrow keys should move the selection, and `Enter` should execute the same target-level focus/open action used by the numbered window shortcuts.
- Leader-based previous/next window cycling should follow the most recently focused targets within the workspace rather than the static workspace definition order. Each repeated cycle sequence should traverse a frozen ordering snapshot so `previous` and `next` walk the full target set instead of bouncing between the last two windows.
- Window rows in the selected workspace should expose numbered shortcuts for direct focus.
- Numbered window focus shortcuts should keep the saved workspace-settings order for configured browser sessions and processes, and append newly added ad-hoc windows after those configured rows.
- Window focus actions and numbered shortcuts should follow one target-level rule: make that target available now.
- Focusing a target from the app UI or command palette should keep Spaces visible instead of hiding the app after the target receives focus.
- A live target should receive focus. A configured target that is not live should be opened directly instead of requiring a full workspace launch or restart.
- Opening a configured browser session, process, or coding agent from a stopped workspace should move that workspace out of the stopped state immediately.
- Partial runtime is a first-class workspace state: some configured targets may be live and focusable while others remain directly openable.
- Window focus actions must operate on one target only and must not route through full-workspace `Launch` or `Restart` semantics.
- Missing configured processes in Alerts should open that one configured process directly and reuse the same configured row instead of creating a duplicate row.
- Alerts rows should show the tracked window or process name as the primary label and the target detail, such as a browser URL or process command, as secondary text.
- Ad-hoc terminal rows should keep their generated focus name as the primary label and use the live terminal window title as secondary text.
- CLI-driven focus through `spaces open <name>` should require an explicit tracked window target instead of picking an arbitrary window.
- CLI focus should use unique names across focusable browser sessions, processes, and coding-agent terminals, and `spaces open <name>` should require one of those names explicitly.
- Configured workspace processes and browser sessions must always have explicit names; Spaces should reject unnamed entries instead of falling back to commands or URLs as identities.
- Focus target discovery may remain GUI-centric; the CLI does not need a separate read-only discovery command.
- Window-number shortcuts should use a configurable direct-focus modifier plus digits `1` through `9`.
- Shortcut handling must not break normal text-edit shortcuts while an input is focused.
- Recovery affordances should reserve `Cmd+R`; app-data reload should default to leader+`R` so it stays distinct from recovery modals.
- Alerts should default to leader+`A`.
- Every keyboard shortcut the product supports must be configurable from the GUI settings panel.

## Coding-Agent Integration
- Coding agents can explicitly report lifecycle events through `spaces signal`.
- Agent status events are not implied by `import`, `start`, or `restart`, but workspace launch should open any configured coding-agent rows so they appear alongside runtime-managed agents under one `Coding Agents` section.
- `spaces signal` should support explicit `init`, `start`, `waiting`, `done`, and `exit` events.
- Agent events from unsupported terminal hosts should be dropped instead of recorded. Coding agents run from tmux are not supported by Spaces and should return an explicit error instead of being inferred onto workspace process terminals.
- `init` should identify the originating terminal and either attach to an already tracked terminal row or create a tracked terminal row for that coding agent.
- Terminal identity should be adapter-driven and consistent across supported hosts: prefer tmux window identity when present, otherwise prefer a stable session/token identity, and only fall back to a yabai window identity when no durable session-like identity exists.
- iTerm2 should use `ITERM_SESSION_ID` as both its hook identity and its durable native terminal identity when available.
- When `ITERM_SESSION_ID` is present, iTerm2 agent events should bind to that session identity directly and must not borrow whichever yabai window happens to be frontmost at event time.
- Ghostty agent tracking should keep two separate identities: a Spaces-issued terminal tracking token for CLI hook attribution and the real Ghostty terminal ID for focus, liveness, and retab rebinding.
- Ghostty agent events without a Spaces-issued tracking token should be dropped instead of being rebound to whichever Ghostty tab or window happens to be frontmost.
- Ghostty focus may fall back from `terminalNativeID` to the stored hook token only when resolving an already tracked terminal row in the same workspace; it must not guess from the frontmost Ghostty tab/window.
- Coding-agent rows should render after browser and process rows so non-agent shortcut ordering stays stable when agents appear or disappear.
- Configured and ad-hoc coding agents should share the same `Coding Agents` section rather than rendering as separate launcher and runtime sections.
- Every tracked window row should have a unique visible name within its workspace. Two coding-agent rows must not share the same name.
- Configured coding-agent launcher names are reserved within the workspace. An ad-hoc coding agent that reports the same label should be auto-renamed with a numeric suffix instead of colliding with the configured launcher slot.
- Launching a configured coding agent is idempotent for its reserved slot: if that coding agent still has a live tracked terminal, Spaces should keep the existing row instead of deleting and recreating it.
- `start` should show a spinner, `waiting` should show a warning indicator and count toward Alerts and dock attention, and `done` should remain in Alerts and dock attention until dismissed while still rendering as a green dot on the workspace row. `idle` should render as a gray dot without creating Alerts attention.
- `exit` should return the row to idle when the terminal is still open; if the terminal is closed, ad-hoc agent rows should be removed immediately, including when background runtime refresh detects the terminal closure after the fact, while rows linked to workspace process terminals should remain idle.

## Errors and Feedback
- Long-running actions should show visible progress.
- Failure states should be explicit and actionable.
- The GUI should prefer inline guidance over silent failure or hidden background behavior.
- Background sidebar/runtime refresh should update in place without replacing the current detail pane or resetting the selected workspace tab.

## Update Experience
- The app should check for updates periodically and allow manual update checks.
- Update discovery and installation should use one stable Sparkle appcast feed.
- Manual downloads may still be published separately, but the in-app updater should not depend on GitHub release APIs.
- The manual-download DMG should present a single guided installer entry point that installs both `Spaces.app` and the required `spaces` CLI together.
- `spaces --version` should report the current version.
