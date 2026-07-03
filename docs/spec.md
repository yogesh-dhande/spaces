# Spaces Spec

This document defines how Spaces should behave from the user's point of view. It is the source of truth for UX and product semantics. Implementation choices and the rationale behind them belong in [implementation.md](implementation.md).

## Product Intent
Spaces is a local macOS control plane for switching between coding contexts quickly.

It should reduce the overhead of:
- creating and cleaning up workspaces and worktrees
- starting the right processes with the right service ports and environment
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
- Focus a browser session by activating its tracked Chrome window and selecting the tab whose URL matches the session, falling back to the first tab when no match is found.
  Matching by URL keeps focus on the intended page even when the user reorders tabs or appends new ones during normal browsing in that window.
- Closing a terminal pane detaches the client from the session it hosted.
  Closing a process or coding-agent pane leaves the runtime running and recoverable through focus. Closing an ad hoc terminal's pane stops that ad hoc session. Explicit Stop and Restart controls own process and coding-agent runtime termination.
- Keep workspace lifecycle separate from runtime health.
  `Running` and `Stopped` should stay easy to explain, while failed processes or stale tracked windows surface as warnings on top of that lifecycle state.
- Require explicit tracked-window targets for GUI-driven and harness-driven focus.
  Focus should not guess which window the user meant, because arbitrary focus becomes unpredictable as workspaces collect multiple windows.
  Example: one workspace may have a frontend browser, an admin browser, an API terminal, and a coding-agent terminal all open at once. If the user clicks Focus in the GUI or a test harness focuses a named target, Spaces should not silently pick whichever window was captured first or happened to survive most recently. The user may want the admin browser now and the coding-agent terminal five seconds later. Requiring an explicit tracked window target keeps focus behavior deterministic.
- Never resize or reposition tracked windows unless initiated by the user.
  Spaces should respect where the user placed each tracked window, because it cannot infer whether the user wants side-by-side windows, overlapping windows, or some other layout that includes non-Spaces windows.
- Never control windows that Spaces does not explicitly track.
  Spaces should not hide, move, resize, or otherwise manipulate unrelated windows, because the user may intentionally keep an untracked window visible next to a tracked workspace window.
- Keep coding-agent events explicit.
  Workspace creation, start, and restart actions must not infer agent lifecycle, because only the agent can accurately report when it actually initialized, started active work, is blocked, is done, or exited.
- Use explicit names as the stable identity surface for focusable browser sessions, processes, and coding-agent terminals.
  Names express purpose and intent, stay meaningful when URLs or process commands change, and avoid collisions where multiple coding agents may run the same command. Those names must be unique within a workspace's combined focusable set so GUI and harness focus can target one unambiguous window by name.

## Core Concepts

### Project
A project is a codebase plus reusable templates:
- setup and stop scripts
- service definitions
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
- `Stopped` means the workspace is idle. This covers two cases that behave the same: a workspace Spaces has never launched, and one Spaces explicitly stopped after a run. In both, nothing is running and the workspace is directly launchable.
- Stale runtime leftovers should not silently change `Stopped` back to `Running`; they should surface as warnings on top of the existing lifecycle state.

### Window Set
A workspace owns a tracked set of dedicated windows, such as:
- process terminals
- browser windows for browser sessions that have been opened on demand
- coding-agent terminal windows

Spaces focuses those windows; it does not decide their geometry.

### Terminal sessions
Every terminal runs in the built-in terminal, never an external terminal app. A workspace can hold three kinds:
- a process terminal hosting a configured process
- a coding-agent terminal hosting a configured or detected coding agent
- an ad hoc terminal the user opens directly (for example through `New terminal`), rooted at the workspace directory

## Startup
- On launch, the main window should immediately show a neutral loading state while Spaces loads workspace data, so startup never presents a blank window.
- Spaces focuses workspace browser sessions by scripting Google Chrome through Apple Events, which macOS gates under the Automation privacy permission ("Spaces wants to control Google Chrome"). This Automation permission is the only first-run prerequisite; there is no Accessibility requirement and no other onboarding or setup step.
- When that permission is missing — not yet granted, or previously denied — first launch shows a blocking "Allow Spaces to control Google Chrome" setup screen before the main workspace UI. The screen offers:
  - a Grant Access button that raises the macOS consent prompt while the permission is still undecided, and
  - an Open System Settings button that deep-links to System Settings ▸ Privacy & Security ▸ Automation for the case where the permission was denied (macOS does not re-prompt after a denial), alongside a Recheck action.
  - The screen polls the permission and auto-advances to the workspace UI the moment access is granted, so granting through System Settings does not require relaunching Spaces.
- When Google Chrome is not installed, or the permission state cannot be determined, Spaces does not block and opens straight to the main UI, because there is nothing to grant. The macOS Automation prompt then appears the first time a browser session is focused.
- Installed builds should default to one shared profile rooted at `~/.spaces/`, while repo-local development builds should default to one profile per git worktree. (Profile and environment-override mechanics live in [implementation.md](implementation.md).)
- App launch should not stall on the user's shell startup files while resolving command locations.
- Spaces should treat its built-in terminal as the only supported terminal path and should not require any external terminal app.
- Workspace processes launch, stop, recover, and reopen through Spaces-owned built-in terminal sessions.
- Launching a second app instance for the same profile should fail immediately and identify the existing owner process.
- Launching a different profile while another Spaces instance already owns desktop-global control should still load profile data and windows, but it should start in passive mode with local in-app shortcuts only and a compact status that global shortcuts are unavailable.

## Projects
- Users can add a project from a directory path or a git URL.
- The New Project form opens in its own dialog window with the same header and chrome as the Settings window, dismissed with the close button, Cancel, or `Esc`.
- The folder source is a path text field with directory autocomplete, not a native file picker, so projects can be created by path on the local Mac or on a selected remote device. As the user types, suggestions come from the selected device's filesystem; on commit the selected device validates the path and loads any `spaces.yaml` before the project is saved.
- Git imports should create an app-managed clone and default workspace.
- Non-git projects should create one default workspace for the project directory.
- Project creation and deletion should show progress without freezing the UI.
- Sidebar project rows expand or collapse their workspace lists by clicking the row's name area; rows carry no disclosure chevron.
- Sidebar project row collapsed state should persist across app restarts and sidebar refreshes.
- Sidebar project rows should expose a dedicated settings action that opens project settings in a dialog. Opening the dialog leaves the current sidebar selection and detail pane unchanged and does not highlight the project row.
- The project settings dialog matches the New Project dialog: a header with the project name and a close control, the directory path at the top of the body, then project-level configuration sections and footer actions. Closing the dialog discards unsaved edits; Save persists them.
- Project settings should support GUI-only `spaces.yaml` import and export. For local projects, `spaces.yaml` lives in the project directory. For app-managed Git imports, it lives in the checked-out default workspace directory, not the bare clone under the managed repos root.
- Project creation uses a source step followed by a settings step. Entering a folder path loads an existing `spaces.yaml` from that directory into the visible settings before the project is saved. Choosing a Git URL clones the repository, creates the default worktree, and loads `spaces.yaml` from that worktree before the project is saved; invalid YAML prevents the settings step and rolls back the managed clone and worktree. If the user leaves a prepared Git project without saving, retrying the same URL refreshes the app-managed clone and default worktree instead of failing on the existing directories. Changing the source replaces the visible settings, including open script editor text and open row drafts. The final save persists the visible settings, including edits made after YAML loading.
- In the GUI, Git project creation asks for confirmation before replacing existing Spaces-managed clone or worktree folders that are not registered to any project or workspace. Canceling the confirmation leaves the New Project form active and does not start the clone.
- Export writes the saved project template as a full canonical `spaces.yaml`, overwriting the file at the project config path. Export requires project settings to have no pending unsaved edits, including open section editors and row drafts. Import loads a preview into the visible project settings without changing persisted project or workspace state, replacing open row drafts and editors with the imported rows.
- Saving project settings persists the visible project template. It does not rewrite any existing workspace settings, including the default workspace, unless Save confirms `Update All Workspaces` for a pending imported configuration; in that case Save applies the visible template to every workspace, including archived workspaces. `Project Only` saves only the project template, and `Cancel` leaves project and workspace state unchanged. The project settings dialog offers a discard action for pending imported configuration so the user can return to the previously saved project template before saving; discarding replaces open row drafts and editors with the saved rows.
- Expanding a project that has no workspaces shows a single muted `No workspaces yet` hint row so the disclosure toggle always reveals content; the hint is not selectable.
- Sidebar workspace rows show the git branch name. A non-git project owns a single workspace whose directory is the project directory, so it renders as one flat selectable row labeled with the project folder name, without a disclosure chevron or a nested workspace row.
- Sidebar workspaces under a project are ordered with the default workspace first, then the rest sorted alphabetically by display name (branch, or folder name for non-git) using natural, case-insensitive comparison, so the list is easy to scan.
- Every visible workspace row shows a compact vertical list of its runtime targets beneath it — browser sessions, configured processes (running or not), ad hoc terminals, and coding agents — in the same order the numbered window shortcuts and window cycling use. Each target row shows a kind icon tinted by run state (running, exited, or not started) and the target name. When the workspace is selected, target rows lead with their `⌘<number>` shortcut chip to the left of the kind icon, matching the command palette's chip-icon-title ordering; every target row reserves the chip's slot whether or not it renders, so rows stay vertically aligned across workspaces. A non-git project's flat row lists its single workspace's targets the same way.
- Left-clicking a sidebar target row selects the owning workspace and opens or focuses the target — the same behavior as its numbered shortcut or a command-palette row: terminal-backed targets open or focus their pane in the workspace's panel, browser sessions open or focus their dedicated Chrome window, and not-yet-running configured processes and agent launchers start.
- The selected workspace's right panel is a tabbed terminal panel scoped to that workspace, and nothing else: one flat tab strip at the top, the selected tab's panes filling the rest edge to edge, and the workspace footer strip at the bottom. The main window shows no window title: the tab strip sits in the titlebar row itself, sharing it with the traffic lights (it starts at the sidebar divider and follows it), and the app identity row lives in the sidebar footer. The titlebar row keeps its native behaviors — dragging and double-click zoom work from its empty areas, including the tab strip's unoccupied space. Each tab holds one or more panes; every pane hosts a terminal session (future content kinds may join). A terminal session has at most one pane anywhere — opening an already-open session focuses its existing pane instead of duplicating it.
- Tabs render flat — no pill or chip outline — with the selected tab marked by full-color text and an accent underline; each tab has a close glyph. Clicking a tab selects it and returns keyboard focus to the pane that most recently held focus in that tab. Right-clicking a tab offers Rename, which edits the tab's name in place — the title becomes an inline field, like sidebar row renames (Return or clicking away saves, Esc cancels); a custom tab name persists with the layout and survives relaunch, and clearing it returns the tab to its derived title (its first pane's target). Tabs can be named independently of their panes' sessions, which matters once a tab holds several panes.
- Panes carry no chrome of their own — no header, border, or outline; the terminal surface fills the pane. Pane and derived tab titles use the runtime target's name (the same name the sidebar target row shows, e.g. `codex` or `npm:dev`), not the terminal's own window title. The tab strip's right side holds the pane actions: split right, split down (both act on the selected tab's focused pane), and new tab. Splitting opens the command palette in a session-picker mode listing `New terminal session` first and then existing sessions in scope — the workspace's sessions for a workspace panel, and every loaded device's sessions across all workspaces for a panel window. The picker shows up to ten rows before any typing, and typing searches the full list. The chosen session fills the new pane, moving it from any pane it already occupied. Pane and tab sizes from divider drags persist.
- `⌘W` closes the focused pane: the last pane of a tab closes the tab, and a panel window's last tab closes the window. The pane's session keeps running — closing a pane never stops anything by itself.
- The `New terminal` shortcut and the tab strip's `+` button start a fresh ad hoc terminal session and open it as a new tab. In the main window the tab lands in the selected workspace's panel; in a panel window it lands in that window, targeting the focused pane's workspace.
- Built-in terminals use the Spaces-owned theme: colors (background, text, cursor, selection, ANSI palette) come from the app's theme, with light and dark variants matching the OS appearance at launch so terminals read as part of the app shell; switching the OS appearance mid-session fully applies after relaunch. Personal Ghostty configuration on the machine — themes, fonts, or any other setting — never affects built-in Spaces terminals. The terminal surface renders at a fixed 12pt font so terminal text matches the scale of the surrounding UI.
- A terminal pane can live in its own panel window: a separate Spaces window holding the same tabbed panel surface, not scoped to one workspace, so its tabs and splits may mix sessions from any workspace or device. Moving a session there removes it from its previous pane — never copies it. Sidebar clicks, numbered shortcuts, and the command palette focus a session wherever its pane lives, including panel windows. Closing a panel window's last pane (or the window itself) closes the window; the sessions keep running, they just lose their panes.
- Panel windows and their frames persist across app relaunch and reopen automatically once the devices their sessions belong to have connected, pruning panes whose sessions are gone; a window whose sessions are all gone does not reopen.
- Explicitly stopping or restarting a runtime target terminates its session and removes that session's pane (restart relaunches the target as a fresh session, which reopens as a pane when it is next focused). A session that exits on its own — a process crash or error, with no explicit stop — keeps its pane in place showing the final render so its last output stays readable. Starting a target never removes a pane. Otherwise panes and tabs disappear only through their explicit close controls.
- Switching the selected workspace (including arrow-key navigation) swaps the right panel to that workspace's panel with its previously selected tab and focused pane restored. Panel layouts — tabs, panes, splits, and the focused pane — persist across app relaunch, reattaching to sessions that are still alive and dropping panes whose sessions are gone.
- While a terminal pane has keyboard focus, every non-⌘ key (including arrows and ctrl chords) belongs to the terminal; ⌘ shortcuts run app actions first and otherwise fall through to terminal-owned ⌘ bindings.
- Right-clicking a sidebar target row shows a context menu with Start, Stop, and Restart (each shown only when the action applies to the target's current state), Rename, and Open in New Window. Open in New Window moves the target's terminal session into its own panel window (enabled only for targets that have a session; browser targets never show it). Rename edits the name inline in the row; Return saves and Esc cancels. Renaming an ad hoc terminal renames its session; renaming a configured process, coding agent, or browser session renames its workspace configuration entry, so a running process picks the new name up on restart.
- Sidebar workspace rows expose a settings action that opens workspace settings in a dialog, like project rows do for project settings. A non-git project's flat row stands in for its single workspace and has no separate template to edit, so its settings action opens that workspace's settings rather than project settings.
- The workspace settings dialog matches the project settings dialog chrome: a header with the project and workspace name and a close control, the directory path at the top of the body, then the workspace's configuration sections for Browser sessions, Processes, Coding agents, Services, and Stop script. Each section shows its configured items as rows and expands inline into an edit form when the pencil icon is clicked; the `+ add` header button appends a draft item; every edit saves immediately. Service rows should show the assigned port number and the derived routed URL as secondary text next to the service name; on a remote workspace whose service is actively forwarded to this Mac, the port shows as `<remote port>:<local forwarded port>` (e.g. `3000:52341`) so the user can see and debug both ends of the forward, while a local workspace shows just its assigned local port. The service-name input is validated as a unique DNS label (lowercase letters, digits, and hyphens, starting and ending with a letter or digit). The dialog is configuration-only: sections show edit and delete controls but no run, stop, restart, or focus actions — runtime control lives on the sidebar target rows.
- The sidebar's Alerts entry sits at the top of the sidebar (bell icon, title, shortcut hint, and unread badge), and the sidebar's footer strip holds the app identity row: logo, app name, and the devices, settings, and reload actions (plus a warning icon while another Spaces instance owns desktop control). The sidebar and right-panel footers share one height, so their separators meet in a single line across the window. The right panel owns a footer strip showing the selected workspace's details in one compact row: a run-state dot, the workspace name (its git branch, or the project folder name for non-git; read-only — renaming a git workspace's branch changes the name), a runtime warning icon when something needs attention, the git branch when one is recorded and differs from the workspace name, the directory path (selectable, so it can be copied with `⌘C`), the focused pane's title, and the notes, launch/restart, stop, and overflow actions. The footer stays with the workspace across the panel, loading, and setup views, and clears when no workspace is selected.
- Workspace notes are edited from the footer's notes button, which opens a small editor popover (⌘↩ saves, Esc closes); the button is tinted when notes exist and its tooltip previews them. The `⋯` overflow button exposes Copy path and Reveal in Finder, with Reveal in Finder available as a keyboard-invokable menu item via `⌘⇧F`.

## Devices and Pairing
- Every Mac or Linux `spacesd` is authoritative for its own projects, workspaces, configuration, runtime rows, terminal sessions, notes, alerts, paired clients, daemon name, TLS identity, database, runtime files, and workspace filesystem.
- macOS and iOS apps are thin clients over paired daemons. Projects and workspaces are created separately on each device; Spaces does not share workspace records across devices. Each project and workspace has a globally unique identifier so the same repository on two devices is two distinct entries.
- The macOS sidebar lists every paired device at once: the local Mac plus each paired remote device as its own section grouping that device's projects and workspaces. The local device and each remote device load independently, so a slow or unreachable device — including the local Mac when its `spacesd` daemon is down — shows its own loading or offline state without blocking the rest. An offline device header shows the same muted "offline" caption, with the failure reason available on hover. With a single online device the sidebar is a flat project list with no device header; a lone offline device still shows its header so the offline caption and reason stay visible.
- The iOS client connects to one selected device at a time and shows an add/connect device state when no device is paired.
- Device API traffic uses TLS with pinned daemon identity plus a per-client full-control token. Clients reject endpoint identity mismatches before sending authenticated requests.
- `spaces pair` opens a short-lived pairing window on the same-machine daemon and prints `spaces://pair?...` details for terminal-driven iOS pairing. The Mac Devices settings section shows QR codes for pairing iPhone and iPad clients with any device already connected to the Mac client.
- Pairing stores the pinned daemon identity and client token in Keychain. Client SQLite backup files contain paired-device metadata only and do not contain pairing tokens.
- Pairing a remote device for macOS asks for SSH host, user, and port, validates SSH with `BatchMode=yes` and `StrictHostKeyChecking=yes`, requires a remote Mac to have the DMG install markers, prepares supported Linux hosts automatically over SSH when Spaces is missing or not responding, runs `~/.spaces/bin/spaces pair --json` on the remote device, then pairs with the Device API at the effective OpenSSH `HostName` and returned API port. Missing or failing SSH is a setup failure for pairing, remote terminal attach, browser forwarding, and editor opening.
- Paired clients have full control of every daemon they are paired with. Paired-client administration is handled by daemon control paths rather than shown as a normal client screen.
- Creating projects, workspaces, terminals, processes, and coding-agent runs targets the daemon that owns the affected row: on macOS that is the device of the selected project or workspace, and on iOS it is the selected device. Reveal-in-Finder is available only for local-device workspaces, while opening the preferred editor works for both local- and remote-device workspaces. Project creation accepts a daemon-side Git URL or an existing daemon-local path.
- The `spaces` CLI targets only the same-machine daemon. It does not create or mutate projects, workspaces, or terminals on paired remote devices.
- Remote terminal attach opens a local terminal window attached to the remote daemon session through SSH. Remote browser sessions that target a daemon-local service open through an SSH local forward. Remote editor actions open the daemon worktree through the configured SSH-capable editor, which presents the remote worktree as a local window. Re-opening the editor for a workspace focuses the editor's existing window for that folder instead of opening a duplicate. Opening a remote workspace needs an SSH-remote extension in the editor; when the editor lacks one, Spaces offers to install it before opening.
- Each device stores workspaces under its own workspace root by default. The default root is `~/spaces/workspaces/` for installed macOS and Linux daemons, with app-managed git clones under `~/spaces/repos/`.

## Workspaces

### Creation
- Users can create, update, focus, stop, restart, and archive workspaces from the GUI.
- The CLI should expose `spaces project list`, `spaces workspace list`, `spaces workspace create --project <id> --branch <branch>`, `spaces workspace start --workspace <id>`, `spaces workspace restart --workspace <id>`, `spaces pair`, `spaces pair --json`, `spaces agent signal --workspace <id> --session <terminal-session-id> <event>`, `spaces terminal list`, and `spaces mcp`.
- `spaces mcp` runs a Model Context Protocol stdio server that an MCP client such as Claude Code or Codex launches and drives. It exposes project, workspace, and terminal list/tail/send tools. Terminal send accepts either UTF-8 text or explicit byte values. Agent lifecycle signals are CLI-only hooks so coding-agent shell integrations can report explicit events without making those hooks available as agent-callable MCP tools.
- `spaces import` is not a public command. Workspace creation must be explicit about project and branch because registering a workspace creates daemon state, allocates runtime resources such as ports, and can run setup work.
- Workspace start, restart, and stop actions target the active daemon. Terminal commands should support listing available sessions by session ID, runtime state, and working directory and printing a clear empty-state message when none are available, sending text, sending named keys, opening native Spaces-owned session windows in owner-seeking mode, and transferring input ownership between attached clients.
- App-launched built-in workspace terminals, process windows, and coding-agent windows should be owned by the per-user `spacesd` daemon and reopen onto the same live shell session across `SpacesApp` quit and relaunch.
- Quitting `SpacesApp` while service-owned terminal sessions are running should prompt the user to quit while keeping sessions running, stop all sessions and quit, or cancel. Keeping sessions running is the default.
- `spaces terminal` sessions should remain owned by a per-user `spacesd` daemon so they can survive `SpacesApp` quit and reopen against the same live shell session as long as the service remains alive and the session lifetime is still valid.
- `spaces terminal command` should create persistent service-owned sessions so commands started before a native Spaces window attaches remain discoverable through `terminal list` and controllable through the terminal CLI.
- The spacesd daemon should start the first-party Device API listener on launch, keep a stable endpoint while it is running, and advertise nearby pairing metadata with Bonjour when the platform supports it.
- The Mac user settings open as a floating dialog window with a two-panel layout: a header bar with the Settings title and a close control, a left navigation list of General, Shortcuts, Devices, and MCP sections, and the selected section's content in the right panel. The dialog floats over the main window, leaving the current sidebar selection and detail pane untouched. The General section holds the preferred editor control, and the Shortcuts section holds the keyboard shortcut editor. The preferred editor picker lists whichever of VS Code, Devin Desktop, and Zed are installed, and notes when a previously saved editor is no longer installed. The MCP section shows per-client `spaces mcp` configuration in tabs for Claude Code and Codex, using the resolved CLI path; the configuration is a read-only block the user selects to copy.
- The Mac sidebar should expose a Devices action next to user settings; it opens the settings dialog on the Devices section. The Devices section lists connected daemons, includes the local Mac daemon when it is available, lets the user choose the active daemon for the home surface, offers a per-device QR pairing window for iPhone and iPad clients, and includes an SSH target form for connecting this Mac to a remote daemon. If the local daemon is unavailable, the section shows the failure inline (instead of a system error) and offers a Restart Local Daemon control that relaunches it and re-checks status. Because the daemon's Device API can be down while its terminals are still live, the control first warns that running terminals, processes, and coding agents will stop and asks the user to confirm whenever any live session exists; it skips the prompt when nothing is running. Long failure messages wrap within the window rather than widening it.
- A device's default name is its machine name. Connected devices can be renamed from either client: right-click a connected device (long-press on iOS) and choose Rename to edit the name in place, then press Return to save or Esc to cancel. Removing a connected device asks for confirmation before disconnecting and forgetting its pairing.
- Built-in process windows should keep a compact metadata header instead of expanding to fit full exported environment wrappers.
- Native Spaces terminal windows should attach to an existing terminal session without restarting the shell, including windows for remote-device sessions.
- Native Spaces terminal windows should not show session metadata chrome such as session ID, cwd, shell, command, renderer, or runtime state during regular use. That information may remain available to diagnostics and tests.
- Owner macOS terminal windows should support standard terminal edit and find shortcuts: `Cmd+V` pastes, `Cmd+C` copies the Ghostty selection, `Cmd+A` selects terminal content, `Cmd+F` opens terminal find, `Cmd+E` searches from the current selection, `Cmd+G` and `Cmd+Shift+G` navigate matches, and `Esc` closes find while returning focus to the terminal. Terminal-control shortcuts such as `Ctrl+C`, `Cmd+K`, `Cmd+Left`, `Cmd+Right`, and modified Backspace remain terminal input or terminal-owned actions.
- Owner macOS terminal windows should paste images from the local Mac clipboard into daemon-owned terminals as daemon-local temp files. `Cmd+V` checks for a decodable clipboard image or image file URL first; when one is present, Spaces uploads the image to the owning daemon, writes it under `/tmp`, and inserts that daemon-local file path into the terminal. When no image is present, `Cmd+V` keeps the normal text paste behavior. `Ctrl+V` with a decodable image uses the same image-path paste, while `Ctrl+V` without an image remains terminal input. Image paste accepts common image formats, normalizes TIFF clipboard data to PNG, and rejects images over 10 MiB.
- Owner macOS terminal windows should open Ghostty-detected terminal links through the system. `http` and `https` links open as URLs, while `file://` links and absolute file paths open as files. Hovered terminal links should show the pointer cursor affordance.
- Attached terminal windows should follow live session metadata where possible, including title and working directory updates emitted by the session backend instead of staying frozen at launch-time values.
- Opening a native terminal window should auto-attempt ownership takeover instead of mounting a passive live terminal surface. While the window is not the active owner it should show takeover and status UI only, and once it becomes owner it should render the current terminal state without restarting or recreating the shell session.
- `Spaces`-hosted terminal windows opened or focused from the app stay visible with the Spaces app instead of following the external-app hide behavior used for browsers, Finder, or editors.
- The first-party iOS client should show a workspace-first home with every non-archived workspace and its mobile-controllable runtime rows inline: configured processes, configured coding agents, and workspace terminals.
- The first-party iOS client should pair directly with a Mac or Linux `spacesd`. The selected daemon owns pairing, auth, overview, workspace mutations, and terminal credentials for that device.
- iOS terminal sessions should use direct pinned-TLS access to the paired `spacesd` with the credential issued for that iOS installation.
- The iOS home should keep search and row filters local to the current app session. The search field should sit beside a filter button, and filter controls should cover row type (`Processes`, `Coding Agents`, `Workspace Terminals`) plus run state (`Not Started`, `Running`, `Exited`).
- iOS row taps should open a terminal when the row has a session. Rows without a live session should route the primary action to running the configured process or coding agent when that action is available. Exited configured process rows with an inspectable terminal session should keep row tap for terminal inspection and expose an inline run action.
- The iOS client should let users create a workspace in any existing project on the active paired daemon. Git projects should expose create-branch or existing-branch mode, branch name, and base branch; non-git projects create a single workspace for the project directory.
- The iOS client should let users open and stop persistent workspace terminals rooted at the workspace directory, and run, stop, or restart configured processes and coding agents through the paired daemon.
- Device API workspace-terminal opens should reserve a stable terminal session ID before shell startup finishes. The mutation overview includes the reserved session with `TerminalSessionState.starting`, and workspace terminal rows use the existing public `running` row state so Mac and iOS clients can open terminal detail immediately. While the session is starting, terminal detail shows a preparing state and keeps input, takeover, and control actions unavailable until the daemon publishes control and subscription availability. If startup fails, the terminal detail can show the failed runtime state and workspace rows stop treating the session as actionable.
- The iOS client should discover nearby daemons, authenticate once from a `spaces://` pairing link, store the issued credential, transport key, and daemon endpoint fingerprint, reconnect without prompting on later launches, treat bundle identity as policy metadata, and clear the stored credential with a re-pair prompt if the daemon later rejects that client token or endpoint identity.
- The iOS recovery action should require an existing paired daemon connection. It recovers only the Mac app process after a quit or crash while macOS `spacesd` remains reachable; daemon crashes, network loss, and unpaired clients still require normal recovery or pairing.
- The iOS client should browse live workspace terminal sessions and ended Spaces-backed process or coding-agent rows that still have a tracked terminal identity. Live rows auto-attempt ownership takeover when opened and render one session at a time through a Ghostty render-frame backed terminal view only after ownership is acquired. Ended rows are read-only, skip attach, takeover, input, resize, and reconnect loops, and show the persisted final Ghostty render when one is available.
- The iOS terminal detail chrome should keep a stable height across owner preparation, takeover, and ready states so status changes do not resize the terminal viewport after ownership handoff.
- The iOS terminal detail chrome should show the selected process, coding-agent, or workspace-terminal row name when the session maps to a workspace runtime row. Runtime lifecycle controls should live behind a compact trailing `...` menu with run, restart, and stop actions when available.
- The iOS terminal keyboard accessory should use a compact fixed-height toolbar: the scrollable key strip is ordered `tab`, `/`, `~`, `|`, `-`, `_`, `esc`, `ctrl`, `cmd`, `opt`, iPhone uses tighter button widths and spacing than iPad, and a single arrow-key joystick plus the keyboard hide/show control stay pinned on the trailing edge. The joystick is a relative thumbstick: the touch-down point is neutral, so sliding the finger toward a direction sends that arrow key and holding the slide repeats it so the cursor moves many steps, while a stationary tap sends nothing. Modifier keys apply to the next compatible text, arrow, or Backspace input for terminal line-editing chords, and `cmd+k` clears the terminal-owned screen and scrollback.
- The iOS terminal viewport should use the available terminal width and size to the visible render area above the software keyboard and accessory toolbar so bottom rows and the prompt remain visible with long terminal content.
- iOS terminal scrollback should follow touch movement proportionally, with small swipes producing small precise scroll changes instead of discrete one-row jumps.
- iOS terminal taps should open Ghostty-detected links before applying tap-to-focus behavior. Non-media web links open externally. Image and video links, including readable Mac file paths exposed by the paired bridge and direct HTTPS media URLs, preview inside Spaces with an `Open In` action.
- Ad hoc built-in terminal windows opened from Spaces, including the `New terminal` shortcut path, should remain listed in the sidebar's runtime-target list even before their native window ID has been backfilled.
- Opening a built-in `Spaces` terminal from the app should not block the sidebar window while the session backend becomes ready; session bootstrap latency may still exist, but the workspace UI should stay interactive during that wait.
- Opening a local built-in `Spaces` terminal window from a reserved workspace-terminal session should present immediately with a preparing state while the shell and live renderer become available. Input and terminal controls remain disabled until the session publishes control and subscription availability.
- When Spaces focuses an already-open built-in process window from the normal workspace flow, the owner attachment should still belong to that client and remain ready for input without restarting the session.
- Configured process and coding-agent rows should have one current Spaces terminal session identity shared by Mac and iOS. Launch, focus, restart, and mobile overview paths should reuse that identity while it is current instead of creating duplicate configured rows or duplicate terminal sessions for the same configured slot. Configured rows remain visible after their process exits when they have a terminal identity, so Mac and iOS can open the ended session's final render instead of hiding the configured slot.
- Restarting a configured process or coding agent should replace the previous Spaces terminal identity cleanly: if the old native window is still open, Spaces should claim it for the replacement session or close it before the replacement becomes the current running session, so an exited configured window does not remain beside a running replacement.
- A terminal session may have one active owner client and one or more non-owner viewer attachments recorded at the same time.
- Closing a process or coding-agent built-in terminal window detaches that native window while preserving the runtime and session identity for later focus. Closing an ad hoc workspace terminal window terminates its service-owned terminal session. Stopping a workspace also terminates ad hoc built-in terminal sessions owned by that workspace.
- Ad hoc built-in terminal sessions should stay alive while any local client or recently active remote/device client remains attached and should clean up once the final live attachment detaches or expires unless the user explicitly closes the terminal window or stops the workspace.
- Only the active owner client may send input or resize the terminal; stale owners and stale resize events are ignored.
- The Mac app should remain alive while it coordinates native windows or client-driven terminal ownership changes even if the main window is hidden or the app is backgrounded.
- Live non-owner terminal windows on macOS and iOS should show takeover and status UI instead of terminal content. The macOS viewer window presents a concise centered status message plus a Take Over action rather than the full session detail stack. If the session has already ended and a final Ghostty render is available, that final render may still be shown with terminal-ended chrome.
- The New Workspace form opens in its own dialog window with the same header and chrome as the Settings and New Project windows, dismissed with the close button, Cancel, or `Esc`.
- For git projects, the new-workspace form shows three inline inputs with no advanced section: branch (create-branch or use-existing mode), base branch, and notes. There is no separate title or directory-name input.
- Git workspace creation must require an explicit branch choice. `Create branch` must reject any branch name that already exists, while `Use existing` is the only path allowed to attach or revive a workspace on an existing branch.
- The checkout directory name for a git workspace is generated automatically as a non-conflicting managed directory name, decoupled from the branch name; it is not user-editable.
- A git workspace's display name is its branch, and a non-git workspace's display name is the project folder name; there is no separate, editable title. Git branch identity determines whether a workspace is revived or conflicts with an existing archived record.
- Archiving a git workspace should offer optional local-branch and remote-branch deletion checkboxes so the user can clean up branch names when the workspace is no longer needed.
- Workspace creation should feel fast in the GUI: once the workspace record and directory exist, the New Workspace form dismisses and selects the new workspace immediately rather than waiting for the setup script. A long-running setup script then runs in the background and its progress streams in the selected workspace's setup screen.
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
- Closing a process terminal window leaves the process running. If a tracked process window becomes stale while the process remains alive, Spaces should recover the terminal view and reattach when the user opens a new window for it.
- Workspace titles and tracked-process names are user-controlled text. They may contain visible separator-like substrings without breaking window creation, listing, or focus recovery.
- Editing workspace settings while a workspace is already running must not start or stop browser sessions or coding agents as part of save-time reconciliation. Process name and on-exit edits should update tracked running processes immediately, while command edits should require explicit confirmation to restart the affected running processes; canceling that prompt should leave the existing process configuration unchanged. New configured rows should appear immediately with their non-running status so the user can decide what to open or recover.
- Process commands run as terminal-style shell command strings through the user's resolved login shell.
- Process commands support normal shell behavior such as environment assignment, `cd x && y`, pipes, redirection, command substitution, and shell expansion.
- Configured coding-agent launchers should run inside an interactive login shell so user shell PATH and tool initialization are available to commands such as `claude`, `codex`, or `opencode`.
- Configured coding-agent rows should support direct run, stop, and restart controls. Stop should close the tracked native terminal window when present, terminate the backing built-in terminal session, remove runtime state, and keep the configured launcher available. Restart should relaunch configured or claimed launcher rows and report a clear unsupported action for unconfigured live agents.
- Terminal panes carry no runtime controls of their own; start, stop, and restart for the pane's process, coding agent, or ad hoc session live on the sidebar target rows' context menu. Kept-open exited terminals keep showing their final render and stay stoppable/restartable from the sidebar while the configured row still exists.
- App-level configuration is changed in the app only, not through `spaces`.
- The project and workspace editors validate process commands when they are saved. Process commands must be non-empty.
- Stop shuts down tracked runtime state and closes tracked dedicated windows safely.
- Restart performs a stop followed by a fresh launch.
- `workspace start` is the idempotent "ensure running" path:
  - if stopped, it launches the workspace
  - if running, it restores failed or exited runtime
- `workspace restart` forces a full restart
- Launch should wait for setup to finish and should surface setup failures clearly.
- Workspaces with setup `pending`, `running`, or `failed` show a setup recovery screen instead of normal workspace detail controls.
- The setup recovery screen shows setup status, timestamps, exit code, error text, and the setup log tail. It allows setup retry, Finder reveal, ad-hoc terminal access, and setup log copy/open actions. Failed setup also exposes inline setup script editing before retry.
- Configured processes, coding-agent launchers, and browser sessions must not launch or recover until workspace setup has succeeded. Ad-hoc workspace terminals remain available for setup repair.
- If a configured process exits during startup, launch should surface the recent process output itself and should not open a secondary recovery window that only reports a follow-on attach failure.
- A project declares named services. Each service is a unique DNS-safe name (lowercase letters, digits, and hyphens, starting and ending with a letter or digit, up to 63 characters) and receives one dynamically assigned local port per workspace.
- Each workspace process, setup script, and stop script runs with service and workspace environment variables available:
  - `SPACES_<SERVICE>_PORT` — the assigned local port for that service, uppercased with hyphens turned into underscores (service `admin-ui` is exposed as `SPACES_ADMIN_UI_PORT`).
  - `SPACES_WORKSPACE_SLUG` — a DNS-safe per-workspace slug, such as `login-fix-a3f9c2d1847b`. Git workspaces use the branch name as the readable slug prefix; non-git workspaces use the project name.
  - `SPACES_<SERVICE>_HOST` — the routed hostname `<service>.<slug>.localhost` for that service, without scheme or port, for framework host allowlists.
  - `SPACES_<SERVICE>_URL` — the routed URL `http://<service>.<slug>.localhost:7391` for that service. Reference this directly (for example `$SPACES_WEB_URL`) instead of composing a URL by hand.
- A process binds the port Spaces assigns it, for example `PORT=$SPACES_WEB_PORT npm run dev`.
- A bundled Caddy reverse proxy runs on the Mac and routes `http://<service>.<slug>.localhost:<router port>` to the service's Mac-local upstream, so every workspace reaches its services at stable per-workspace URLs. The default router port is `7391` and is configurable. Routing is plain HTTP on that shared high port, listens only on loopback addresses, and requires no TLS, certificate, or administrator setup because Chrome and Safari treat `*.localhost` as a secure loopback context. Chrome is the supported browser; Firefox does not resolve arbitrary `*.localhost` names by default. Caddy routes every service host whether or not the service has a browser session.
- Local workspace service routes point directly at the service's assigned `localhost` port on the Mac, so service processes can bind either IPv4 or IPv6 loopback. Remote and Linux daemons do not run the Caddy router; when the Mac app observes a running remote workspace with named services, it starts one SSH local-forward process for that workspace with one Mac-owned ephemeral binding per assigned service port and registers Caddy routes to those Mac-local forwards. Focusing a remote browser session that targets a named service reuses the workspace's forward when it is ready and opens it on demand when needed.
- Remote and Linux workspace processes receive `SPACES_<SERVICE>_URL` so app servers can allowlist the browser-facing host or origin for CORS and framework host checks.
- Adding a service from the workspace settings dialog should reserve its port number immediately instead of waiting for the next workspace launch.
- Service assignments belong to the workspace until that workspace is archived. Stopping a workspace must not give its assigned port numbers back to other workspaces.
- When a stopped workspace owns services, Spaces may hold placeholder reservations for those ports, but starting any workspace runtime releases those placeholders so user-facing servers can bind normally. While the workspace is running, assigned service ports are not placeholder-reserved; users resolve conflicts manually if another local process claims an assigned port before the intended server binds it.
- Stopping or restarting a workspace must never close unrelated user windows.
- Runtime health is separate from lifecycle state:
  - `Running` workspaces can be healthy or degraded
  - `Stopped` workspaces can still have stale tracked runtime leftovers that need cleanup or recovery

## Window Management and Focus
- Workspaces map to a tracked set of dedicated windows.
- Spaces should focus the correct window or workspace quickly, even when switching across apps.
- Browser focus should match the intended browser session by URL, not by window title.
- When focusing an already-open browser session, Spaces should activate Chrome and select the tab whose URL matches the session, falling back to the first tab in that tracked window when no matching tab is found.
- Terminal focus should land on the intended dedicated process or agent session.
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
- On macOS the Alerts list and badge aggregate attention items across every paired device, so a single combined badge reflects work needing attention on the local Mac and on remote devices together. Remote attention items are derived from each remote device's overview.
- Attention includes exited processes and coding-agent states such as blocked or done.
- A stopped workspace can still contribute attention items when that helps the user notice something actionable.
- Alerts rows should support direct window focus by click and by the numbered window shortcuts.
- The Alerts sidebar badge and dock badge should reflect the number of visible Alerts attention rows after dismissals are applied.
- Users should be able to dismiss individual Alerts attention items so they disappear from the Alerts list and dock badge until that specific attention event changes.
- Dismissing an Alerts attention item must not hide the underlying process or agent row from the sidebar's runtime-target list.

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
- Leader+up/leader+down move the sidebar selection (Alerts and workspaces) even while a terminal pane has keyboard focus and owns the plain arrow keys; a matched chord is consumed even at a list edge so it never leaks into the terminal.
- The command palette should draw from every navigable workspace target that can appear in the sidebar's runtime-target rows: browser sessions, processes, ad-hoc windows, configured coding-agent launchers, and live coding-agent terminals.
- When the command palette opens with an empty query, it should show Alerts attention items first and then the most recently focused targets across workspaces, capped to the first nine visible rows. If there is no recent focus history, it should fall back to the existing workspace-target order.
- Command-palette rows should show the same status language used by the sidebar's runtime-target rows, including process state and coding-agent state.
- Once the user types a query, command-palette search should fuzzy-match across all workspaces using the workspace display name (branch, or folder name for non-git), target name, and secondary detail text, including compact cross-field queries such as `fu` matching `Frontend` plus `URL`.
- The first command-palette result should stay selected by default, arrow keys should move the selection, and `Enter` should execute the same target-level focus/open action used by the numbered window shortcuts.
- Leader-based previous/next window cycling should follow the most recently focused targets within the workspace rather than the static workspace definition order. Each repeated cycle sequence should traverse a frozen ordering snapshot so `previous` and `next` walk the full target set instead of bouncing between the last two windows.
- Leader-based next/previous window cycling should always mean window cycling, even when the main Spaces window is focused.
- Window rows in the selected workspace should expose numbered shortcuts for direct focus.
- Numbered window focus shortcuts should keep the saved workspace-settings order for configured browser sessions and processes, and append newly added ad-hoc windows after those configured rows.
- Window focus actions and numbered shortcuts should follow one target-level rule: make that target available immediately.
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
- Starting or restarting one configured process or coding agent should not leave a second configured instance visible on Mac or iOS for the same workspace slot. Ad-hoc terminal sessions may remain visible only when they are not represented by a configured process or coding-agent row.
- Alerts rows should show the tracked window or process name as the primary label and the target detail, such as a browser URL or process command, as secondary text.
- Ad-hoc terminal rows should keep their generated focus name as the primary label and use the live terminal window title as secondary text.
- Production CLI-driven focus is not part of the `spaces` command surface.
- Harness-driven focus should use unique names across focusable browser sessions, processes, and coding-agent terminals when it needs to exercise focus behavior.
- Configured workspace processes and browser sessions must always have explicit names; Spaces should reject unnamed entries instead of falling back to commands or URLs as identities.
- Focus target discovery may remain GUI-centric; the production CLI does not need a separate read-only discovery command.
- `spaces terminal tail` should reconstruct the visible terminal screen from persisted session output using the session's last known terminal size, so wrapped lines and full-screen terminal redraws stay aligned with the live session after resizes.
- Window-number shortcuts should use a configurable direct-focus modifier plus digits `1` through `9`.
- Shortcut handling must not break normal text-edit shortcuts while an input is focused.
- Recovery affordances should reserve `Cmd+R`; app-data reload should default to leader+`R` so it stays distinct from recovery modals.
- Alerts should default to leader+`A`.
- Every keyboard shortcut the product supports must be configurable from the GUI settings panel.

## Coding-Agent Integration
- Coding agents can explicitly report lifecycle events through `spaces agent signal --workspace <id> --session <terminal-session-id> <event>`.
- Agent status events are not implied by workspace creation, `start`, or `restart`, but workspace launch should open any configured coding-agent rows so they appear alongside runtime-managed agents under one `Coding Agents` section.
- `spaces agent signal` should support explicit `init`, `working`, `blocked`, `done`, and `exit` events.
- `spaces agent signal` from a terminal should update the owning daemon database for the workspace that owns the session.
- Agent events that cannot be reliably attributed to a terminal must be dropped, not guessed onto the frontmost window.
- `init` should identify the originating terminal and either attach to an already tracked terminal row or create a new tracked terminal row for that coding agent.
- Non-`init` signal events should update the existing agent row for the originating terminal. If no agent row exists, the event may establish one only when the signal context or current terminal runtime identifies the terminal as a coding agent; otherwise the event should be ignored.
- Coding-agent rows should render after browser and process rows so non-agent shortcut ordering stays stable when agents appear or disappear.
- Configured and ad-hoc coding agents should share the same `Coding Agents` section rather than rendering as separate launcher and runtime sections.
- A Spaces-owned ad-hoc built-in terminal can appear in `Coding Agents` when its live foreground process is a known coding-agent command such as `codex`, `claude`, `claude-code`, or `opencode`. Once an agent row exists for that terminal session, foreground process changes do not demote or relabel it.
- A signal-established ad-hoc agent row should remain in `Coding Agents` for its live terminal session even if the foreground process is a shell, wrapper, unknown command, or another known agent command. A live `spaces agent signal ... exit` records the session as idle instead of demoting it; Stop, terminal-session exit, and terminal cleanup own removal or completion.
- Foreground process detection should not infer lifecycle state. `spaces agent signal` remains the source for agent status such as spinning, blocked, done, and exit.
- Every tracked window row should have a unique visible name within its workspace. Two coding-agent rows must not share the same name.
- Configured coding-agent launcher names are reserved within the workspace. An ad-hoc coding agent detected with the same label should be auto-renamed with a numeric suffix instead of colliding with the configured launcher slot.
- Launching a configured coding agent is idempotent for its reserved slot: if that coding agent still has a live tracked terminal, Spaces should keep the existing row instead of deleting and recreating it.
- Focusing an ended configured coding-agent row that still has a Spaces terminal identity should focus the ended session and its final frame instead of launching a duplicate. Launching a replacement belongs to an explicit launcher or restart action.
- `working` should show a spinner, `blocked` should show a warning indicator and count toward Alerts and dock attention, and `done` should remain in Alerts and dock attention until dismissed while still rendering as a green dot on the workspace row. `idle` should render as a gray dot without creating Alerts attention.
- `exit` should return the row to idle when the terminal is still open; if the terminal is closed, ad-hoc agent rows should be removed immediately, including when background runtime refresh detects the terminal closure after the fact, while rows linked to workspace process terminals should remain idle.

## Errors and Feedback
- Long-running actions should show visible progress.
- A workspace or project operation's progress indicator should appear only while that workspace or project is the active selection, so it never covers or blocks actions on an unrelated workspace; navigating away hides it and returning while the operation is still in flight shows it again.
- Failure states should be explicit and actionable.
- The GUI should prefer inline guidance over silent failure or hidden background behavior.
- Remote-device setup should use user-facing status and error messages: Macs need the Spaces app installed, while supported Linux devices are set up automatically over SSH.
- Background sidebar/runtime refresh should update in place without replacing the current detail pane or resetting the selected workspace tab.

## Update Experience
- The app should check for updates periodically and allow manual update checks.
- Update discovery and installation should use one stable Sparkle appcast feed.
- Manual downloads may still be published separately, but the in-app updater should not depend on GitHub release APIs.
- The manual-download DMG should present a single guided installer entry point that installs `Spaces.app`, links `/usr/local/bin/spaces`, `/usr/local/bin/spacesd`, and `/usr/local/bin/spaces-caddy` to the app bundle resources, creates `~/.spaces/bin/spaces` and `~/.spaces/bin/spacesd` helper links to the same resources, and writes the per-user LaunchAgent used by built-in terminal commands and remote Mac pairing.
- When launched from `/Applications/Spaces.app`, the app should keep Spaces-owned helper links and the LaunchAgent plist aligned with the installed app bundle without restarting `spacesd` automatically.
- `spaces --version` should report the current version.

### Daemon Compatibility and Restart
- A client app and the daemon on a device can run different versions because they update on their own schedules. As long as they remain compatible, updating the app does not require restarting the daemon, and running terminals, processes, and coding agents keep going uninterrupted.
- When the running daemon is a compatible-but-older build than the client, the device shows a quiet "update pending" hint; the staged update applies the next time the daemon restarts on its own (reboot, logout, or a manual restart). The app never restarts the daemon automatically in this case.
- When a device's daemon is too old for the current app, that one device is blocked with an explanation while every other paired device stays usable. If instead the app is too old for the daemon, the block asks the user to update the app.
- Because restarting a daemon stops its running terminals, processes, and coding agents, the block first reports how many of each would stop and offers Restart or Defer, so the user can wait until critical work finishes. Restarting the local Mac daemon happens in place; a remote Linux daemon is updated and restarted from the Mac app over SSH; a remote Mac restarts itself and updates through its own updater.
- The iPhone app cannot update a daemon's binary itself. For a remote Linux device it directs the user to update that device from the Spaces Mac app rather than offering a restart that would relaunch the same old build; for other devices it can request a restart to apply an update that is already installed.
