# Spaces Spec

This document defines how Spaces should behave from the user's point of view. It is the source of truth for UX and product semantics. Implementation choices and the rationale behind them belong in [docs/architecture.md](docs/architecture.md).

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
- Process lifetime survives terminal-window closure.
  Closing or losing a process terminal window must not kill the underlying process; Spaces should recover the terminal view and reattach without restarting the work.
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
- On launch, Spaces blocks only on the cheap prerequisite checks needed for its default runtime path: yabai installed.
- Installed builds should default to one shared profile rooted at `~/.spaces/`, while repo-local development builds should default to one profile per git worktree under `~/.spaces-dev/profiles/spaces/`.
- `SPACES_DB_PATH` should override the default database path for the current process, and `SPACES_RUNTIME_DIR` should override the default runtime root for that same resolved profile.
- Startup prerequisite checks may enrich command lookup from the user's login-shell PATH, but that lookup must stay bounded and fall back automatically to the inherited PATH plus standard package-manager locations so shell startup files cannot stall app launch indefinitely.
- When command lookup is enriched from the login-shell PATH, the app's inherited `PATH` remains authoritative. Login-shell entries should only fill gaps that are missing from the launch environment, and built-in package-manager fallbacks should remain last.
- During first-run setup, Spaces should treat its built-in terminal as the only supported terminal path and should not require any external terminal app.
- Workspace processes should launch, stop, recover, and reopen without requiring tmux to be installed.
- The slower yabai readiness step, including service-running and Accessibility validation, should be deferred until the setup flow is actually shown or another yabai-backed action needs it.
- If a deferred yabai readiness check fails during startup, Spaces should switch into the setup flow at the yabai step instead of surfacing a raw shell error dialog.
- If a blocking launch prerequisite fails, the main window shows a guided setup flow starting at the first failing step.
- The setup flow should poll and recover automatically once the missing prerequisite is fixed.
- If all prerequisites pass, the main UI should load without an extra setup window.
- Launching a second app instance for the same profile should fail immediately and identify the existing owner process.
- Launching a different profile while another Spaces instance already owns desktop-global control should still load profile data and windows, but it should start in passive mode with local in-app shortcuts only and a compact status that global shortcuts are unavailable.

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
- The CLI should stay minimal and support `import`, `update`, `start`, `restart`, `open`, `signal`, and low-level `terminal` session commands for Spaces-owned PTY sessions, including listing available sessions by session ID, runtime state, and working directory and printing a clear empty-state message when none are available, sending text, sending named keys, opening native Spaces-owned session windows as an owner or viewer, transferring input ownership between attached clients, and exposing a local TCP proxy for mobile or remote control over the same session boundary.
- Built-in terminal sessions should open in a native Spaces window backed by libghostty while preserving the same per-session `send`, `key`, and `tail` control behavior through the CLI.
- `ghostty-embedded` terminal sessions should remain Mac-owned: mobile or remote clients may view, tail, send, and take over through the shared session control boundary, but the live libghostty surface stays attached to the running Spaces app on macOS.
- Built-in process windows should keep a compact metadata header instead of expanding to fit full exported environment wrappers.
- Built-in owner windows should stay on the libghostty render path. Passive viewer windows should wait for a read-only snapshot of the shared libghostty surface while the session is live, then switch to persisted final output once the session exits; the owner path should not switch renderers behind the user's back.
- `ghostty-embedded` owner windows should follow live terminal metadata where possible, including title and working directory updates emitted by the session backend instead of staying frozen at launch-time values.
- `ghostty-embedded` owner windows should accept direct keyboard input in the terminal surface itself rather than relying on a separate send-input form.
- `ghostty-embedded` owner windows should prioritize the terminal surface over diagnostic chrome. Backend or attachment details may remain visible in viewer or fallback states, but the active owner window should keep the live terminal as the primary experience.
- `ghostty-embedded` owner windows should use the native window titlebar for the live session title and collapse redundant in-window session identifiers or renderer diagnostics when the owner surface is active.
- `ghostty-embedded` owner windows should show prompt and shell output on first open, including workspace-process sessions, without requiring the user to close and reopen the window to reveal already-buffered terminal content.
- `Spaces`-hosted terminal windows opened or focused from the app stay visible with the Spaces app instead of following the external-app hide behavior used for browsers, Finder, or editors.
- Ad hoc built-in terminal windows opened from Spaces, including the `New terminal` shortcut path, should remain listed in the workspace detail view even before their native yabai window ID has been backfilled.
- Opening a built-in `Spaces` terminal from the app should not block the sidebar window while the session backend becomes ready; session bootstrap latency may still exist, but the workspace UI should stay interactive during that wait.
- When the active `ghostty-embedded` owner window has no warning or non-running state to show, its inline header band should collapse so the terminal surface fills the content area instead of leaving a dead strip of chrome above the terminal.
- When Spaces focuses an already-open built-in process window from the normal workspace flow, the owner terminal surface should be ready for immediate typing without requiring an extra click inside the window.
- A terminal session may have one active owner client and one or more passive viewer clients attached at the same time.
- Ad hoc built-in terminal sessions should stay alive while any local client or recently active remote/mobile client remains attached and should clean up once the final live attachment detaches or expires.
- Only the active owner client may send input or control PTY size.
- Viewer windows should remain readable, be able to take over ownership without restarting the underlying shell session, and keep passive chrome minimal: the native titlebar may identify the session, but the in-window experience should prioritize the terminal content plus a clear takeover action.
- For git projects, new workspaces are branch-oriented and should support an existing-branch picker, a new-branch entry path, target branch, directory name, title, and notes inputs.
- Git workspace creation must require an explicit branch choice. `Create branch` must reject any branch name that already exists, while `Use existing` is the only path allowed to attach or revive a workspace on an existing branch.
- Workspace titles are display labels and may repeat within a project. Git branch identity, rather than title text, determines whether a workspace is revived or conflicts with an existing archived record.
- Archiving a git workspace should offer optional local-branch and remote-branch deletion checkboxes so the user can clean up branch names when the workspace is no longer needed.
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
- Configured processes that have never been started, or that were explicitly stopped by the user, should remain idle and directly runnable without degrading runtime health or creating Alerts attention.
- Closing a process terminal window must not kill the underlying process. Spaces should recover the terminal view and reattach to the running process when the user opens a new window for it.
- Workspace titles and tracked-process names are user-controlled text. They may contain visible separator-like substrings without breaking window creation, listing, or focus recovery.
- Editing workspace settings while a workspace is already running must not start or stop browser sessions or coding agents as part of save-time reconciliation. Process name and on-exit edits should update tracked running processes immediately, while command edits should require explicit confirmation to restart the affected running processes; canceling that prompt should leave the existing process configuration unchanged. New configured rows should appear immediately with their non-running status so the user can decide what to open or recover.
- Process commands support two execution modes: `Direct` runs an executable with arguments, while `Shell` runs the command through the app-wide shell setting.
- Direct mode is the recommended deterministic path for plain executable commands such as `scripts/swiftpm.sh build`.
- Direct mode also supports deterministic interpolation of Spaces-provided environment variables such as named ports and `SPACES_*` paths inside executable arguments and leading env assignments, for example `PORT=$PORT1 npm run dev`.
- Direct mode accepts only simple Spaces variable references such as `$PORT1` or `${PORT1}`. Other shell expansions such as `${PORT1:-3000}`, `$$`, or `$?` must be rejected and require Shell mode instead.
- Shell mode supports composite shell behavior such as `cd x && y`, pipes, redirection, and shell expansion.
- App-level configuration is changed in the app only, not through `spaces`.
- The global shell choice for shell-mode processes is configurable in Settings; the default is `zsh`.
- The project and workspace editors validate process commands when they are saved. Direct mode rejects shell-only syntax, while Shell mode requires only a non-empty command.
- Stop shuts down tracked runtime state and closes tracked dedicated windows safely.
- Restart performs a stop followed by a fresh launch.
- `start` is the idempotent "ensure running" path:
  - if stopped, it launches the workspace
  - if running, it restores failed or exited runtime as defined by the command mode
- `restart` forces a full restart
- `update` should own post-creation workspace metadata edits such as title and notes.
- Launch should wait for setup to finish and should surface setup failures clearly.
- If a configured process exits during startup, launch should surface the recent process output itself and should not open a secondary recovery window that only reports a follow-on attach failure.
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
- Focusing a tracked external window should flash a short semitransparent overlay on top of the target window.
- The focus-pulse overlay color should be configured from the GUI settings panel.
- After the GUI focuses or opens an external window, Spaces should hide itself immediately so the target app stays unobstructed.
- When a workspace detail view becomes visible, Spaces should refresh workspace windows and process state asynchronously so stale rows reconcile shortly after the page appears.
- If tracked windows become stale during next/previous window cycling, Spaces should skip them and continue to the next live target.
- Spaces should not poll in the background to verify whether a tracked browser-session window still exists; it should validate that on demand when the user focuses that browser session.
- If direct window focus from the app targets a stale browser session, Spaces should reopen that session in a new Chrome window and update tracking without showing an error modal first.
- If direct window focus from the app targets a stale process window, Spaces should first try to recover silently by reopening the built-in session when the process is still running. If the process is no longer running, Spaces should show a modal warning with `Recover (Cmd+R)` and `Cancel (Esc)`, and the explicit recovery action should restart it inside the built-in terminal.
  - coding-agent windows only show the error state and do not offer recovery
- Spaces should still reconcile stale tracked windows in the background instead of forcing the user to repair state manually.
- Degraded runtime health should appear as a warning on top of the current `Running` or `Stopped` lifecycle state, not as a separate replacement state label.

## Alerts and Health
- The app should surface attention items across workspaces in one place.
- Attention includes exited processes and coding-agent states such as waiting or done.
- A stopped workspace can still contribute attention items when that helps the user notice something actionable.
- Alerts rows should support direct window focus by click and by the numbered window shortcuts.
- The Alerts sidebar badge and dock badge should reflect the number of visible Alerts attention rows after dismissals are applied.
- Users should be able to dismiss individual Alerts attention items so they disappear from the Alerts list and dock badge until that specific attention event changes.
- Dismissing an Alerts attention item must not hide the underlying process or agent row from the workspace detail pane.

## Editing and Shortcuts
- The app should support keyboard-driven use for common actions.
- Project and workspace detail screens should prefer flat section layouts with spacing and dividers over nested bordered cards.
- Global shortcuts should bring Spaces forward and support fast workspace switching.
- The global app-toggle shortcut should hide Spaces when it is already frontmost and visible, and show it otherwise.
- The app should expose a separate global command-palette shortcut that opens a lightweight palette without unhiding or fronting built-in terminal windows.
- The command palette should default to `Cmd+Opt+-`.
- Summoning Spaces from the global app-toggle shortcut should raise only the main window above other apps and onto the active space.
- The global app-toggle shortcut should depend only on whether the main Spaces window is visible. Built-in terminal windows and the command palette must not change whether `Cmd+Opt+=` shows or hides the main window.
- The command-palette shortcut should depend only on whether the command palette is visible. The main window and built-in terminal windows must not change whether `Cmd+Opt+-` shows or hides the command palette.
- When Spaces is summoned, it should select the workspace for the window that was focused immediately before activation when that window belongs to a tracked workspace; otherwise it should show Alerts.
- The app should expose a configurable shortcut leader that supplies the shared modifiers for leader-based shortcuts like workspace navigation, Alerts, editor, terminal, and Finder.
- Up/down arrow navigation inside the main window sidebar should remain a separate concern from global next/previous window cycling.
- The command palette should draw from every navigable workspace target that can appear in workspace detail rows: browser sessions, processes, ad-hoc windows, configured coding-agent launchers, and live coding-agent terminals.
- When the command palette opens with an empty query, it should show Alerts attention items first and then the most recently focused targets across workspaces, capped to the first nine visible rows. If there is no recent focus history, it should fall back to the existing workspace-target order.
- Command-palette rows should show the same status language used by workspace detail rows, including process state and coding-agent state.
- Once the user types a query, command-palette search should fuzzy-match across all workspaces using workspace title, target name, and secondary detail text, including compact cross-field queries such as `fu` matching `Frontend` plus `URL`.
- The first command-palette result should stay selected by default, arrow keys should move the selection, and `Enter` should execute the same target-level focus/open action used by the numbered window shortcuts.
- Leader-based previous/next window cycling should follow the most recently focused targets within the workspace rather than the static workspace definition order. Each repeated cycle sequence should traverse a frozen ordering snapshot so `previous` and `next` walk the full target set instead of bouncing between the last two windows.
- Leader-based next/previous window cycling should always mean window cycling, even when the main Spaces window is focused.
- Window rows in the selected workspace should expose numbered shortcuts for direct focus.
- Numbered window focus shortcuts should keep the saved workspace-settings order for configured browser sessions and processes, and append newly added ad-hoc windows after those configured rows.
- Window focus actions and numbered shortcuts should follow one target-level rule: make that target available now.
- Focusing a target from the app UI or command palette should keep Spaces visible instead of hiding the app after the target receives focus.
- The global `Toggle app` shortcut controls only the main Spaces window, not the built-in terminal windows or the command palette. If a built-in terminal or the command palette is focused, toggling the app should bring the main Spaces window forward instead of fronting all Spaces-owned windows.
- The global command-palette shortcut controls only the command-palette panel. Showing the palette should not hide the main window, and hiding the palette should return focus to whichever window was active before the palette was shown.
- Returning to the main Spaces window from a focused built-in terminal should show the workspace detail view that owns that terminal, matching the behavior of externally hosted terminal windows.
- If the main Spaces window was summoned from a focused built-in terminal, toggling the app again should hide only the main window and restore focus to that same built-in terminal.
- If the main Spaces window was summoned from an untracked external app such as Chrome, toggling the app again should hide only the main window and return focus to that external app instead of leaving Spaces frontmost.
- A live target should receive focus. A configured target that is not live should be opened directly instead of requiring a full workspace launch or restart.
- Opening a configured browser session, process, or coding agent from a stopped workspace should move that workspace out of the stopped state immediately.
- Partial runtime is a first-class workspace state: some configured targets may be live and focusable while others remain directly openable.
- Window focus actions must operate on one target only and must not route through full-workspace `Launch` or `Restart` semantics.
- Starting one configured process must not create Alerts attention for sibling configured processes that were never started or were explicitly stopped. Those rows should stay directly openable in place and reuse the same configured row instead of creating duplicates.
- Alerts rows should show the tracked window or process name as the primary label and the target detail, such as a browser URL or process command, as secondary text.
- Ad-hoc terminal rows should keep their generated focus name as the primary label and use the live terminal window title as secondary text.
- CLI-driven focus through `spaces open <name>` should require an explicit tracked window target instead of picking an arbitrary window.
- CLI focus should use unique names across focusable browser sessions, processes, and coding-agent terminals, and `spaces open <name>` should require one of those names explicitly.
- Configured workspace processes and browser sessions must always have explicit names; Spaces should reject unnamed entries instead of falling back to commands or URLs as identities.
- Focus target discovery may remain GUI-centric; the CLI does not need a separate read-only discovery command.
- `spaces terminal tail` should reconstruct the visible terminal screen from persisted session output using the session's last known terminal size, so wrapped lines and full-screen terminal redraws stay aligned with the live session after resizes.
- Window-number shortcuts should use a configurable direct-focus modifier plus digits `1` through `9`.
- Shortcut handling must not break normal text-edit shortcuts while an input is focused.
- Recovery affordances should reserve `Cmd+R`; app-data reload should default to leader+`R` so it stays distinct from recovery modals.
- Alerts should default to leader+`A`.
- Every keyboard shortcut the product supports must be configurable from the GUI settings panel.

## Coding-Agent Integration
- Coding agents can explicitly report lifecycle events through `spaces signal`.
- Agent status events are not implied by `import`, `start`, or `restart`, but workspace launch should open any configured coding-agent rows so they appear alongside runtime-managed agents under one `Coding Agents` section.
- `spaces signal` should support explicit `init`, `start`, `waiting`, `done`, and `exit` events.
- Agent events that cannot be reliably attributed to a terminal must be dropped, not guessed onto the frontmost window.
- `init` should identify the originating terminal and either attach to an already tracked terminal row or create a new tracked terminal row for that coding agent.
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
