# Spaces Spec

The product rules Spaces follows, from the user's point of view: what happens, when, and why. Implementation and its rationale live in [implementation.md](implementation.md); visual design and reusable interaction patterns live in [design.md](design.md).

## Product Intent
- Spaces is a control plane for switching between coding contexts. It runs as a Mac app, an iOS app, and a `spaces` CLI that also serves MCP for coding agents, all driving a Spaces daemon on each device: the Mac itself and any paired remote Mac or Linux machine.
- It removes the overhead of creating and cleaning up workspaces and worktrees, starting the right processes with the right ports and environment, reopening the right terminals and browser tabs, focusing the right target, and noticing what needs attention (a failed process, a coding agent waiting on a human).

## Non-Goals
- No window geometry or tiling: Spaces focuses windows where the user put them.
- No restoring of exact browser tab order.
- No inspection of external editors' internals.
- No secret management beyond the environment variables processes need.
- Only the integrations Spaces implements: Google Chrome for browser sessions, the built-in terminal for every terminal.

## Key Design Decisions
- Terminal sessions are panes, never windows of their own. Every session lives as a pane in a tabbed panel, and a session has at most one pane anywhere, so focusing a session by name always lands on exactly one place.
- Browser sessions are lazy bookmarks. Nothing opens at launch or restart, because a workspace may carry many URLs and the user needs only some of them; a session opens in Chrome only when focused.
- Closing a pane detaches; it does not stop work. Only an explicit Stop ends a coding agent, and only Stop or Restart ends a process. The one exception is an ad hoc terminal sitting idle at a bare prompt (see [Closing and ending](#closing-and-ending)).
- Lifecycle is separate from health. `Running` and `Stopped` stay simple; a failed process or a stale tracked window shows as a warning on top of the lifecycle state, never as a replacement state.
- Focus always names its target. The GUI and test harnesses focus a named target and never guess (for example "whichever target was captured first"), because a workspace collects several browser sessions and terminals and the user may want any one of them next.
- Names are the identity of every focusable target, so they outlive URL and command changes and tell apart agents running the same command (see [Names](#names)).
- Spaces never moves or resizes a window the user did not ask it to, and never hides, moves, resizes, or closes a window it does not track. The one exception is adopting a Chrome tab whose URL matches the workspace session being focused.
- Coding-agent state comes only from the agent. Creating, starting, or restarting a workspace never infers that an agent started, is working, is blocked, is done, or exited.

## Core Concepts

### Device
- A device is a Mac or Linux machine running a Spaces daemon. Each daemon is authoritative for its own projects, workspaces, configuration, runtime, terminal sessions, notes, alerts, paired clients, and name. The Mac app, the iOS app, and the CLI are clients of the daemons they are paired with.
- Projects and workspaces are never shared across devices: the same repository on two devices is two separate entries. If two devices report the same project (a profile database copied between machines), the Mac shows one project row from the first device in sidebar order, with only that device's workspaces; alerts from both copies still show.
- Creating or changing a project, workspace, terminal, process, or coding agent goes to the daemon that owns the row (on iOS, the selected device).
- Each device keeps workspaces under its own root, by default `~/spaces/workspaces/`, with app-managed clones in `~/spaces/repos/`.

### Project
- A codebase plus reusable templates: setup and stop scripts, services, processes, and browser sessions. The user configures a project once and derives workspaces from it.
- A git project can hold many workspaces. A non-git project owns exactly one workspace, at the project directory, and can never have more.

### Workspace
- An isolated stream of work for one project on one device: a directory, an optional git branch and base branch, optional notes, its own copy of the launch settings, and its runtime.
- Its name is its git branch, or the folder name for a non-git project. There is no separate title and the name is not edited directly; renaming the branch renames the workspace.
- `Running` means an explicit launch, or opening a terminal in the workspace, marked it running. `Stopped` means idle, and a workspace never launched behaves exactly like one explicitly stopped.
- An ended terminal is not runtime: a workspace whose remaining terminals have all ended reads `Stopped` on its own, while their panes stay listed so their output can be read.
- Stale runtime leftovers never flip `Stopped` back to `Running`. A `Running` workspace can be healthy or degraded and a `Stopped` one can hold stale leftovers; either shows as a warning on the lifecycle state.
- Partial runtime is a normal state: some targets live and focusable, others directly openable.

### Home project (`~`)
- Every device's daemon creates one home project, named `~`, at the account's home directory: the place for terminals that belong to no project. It exists without the user adding anything and cannot be deleted.
- It is always a non-git project with exactly one workspace, even when the home directory is a git repository. Projects under the home directory are ordinary projects.
- It holds terminals only: no settings, `spaces.yaml`, scripts, services, processes, browser sessions, notes, Start, Restart, Stop, discovery scan, Editor, file listing, or automations. The daemon refuses Start, Restart, and Stop for it however they are asked, refuses an automation that targets it, and a command that resolves its workspace from the current directory never falls back to `~`.
- Its workspace reads `Running` while a terminal is open in it and `Stopped` once the last one ends.
- Hiding it always lands on its workspace, never the project, so it can always be undone from the Workspaces dialog; a project-level hide of `~` is refused.
- When the account's home directory moves (an account rename, a profile restored under another path), `~` moves with it. If the new home directory is already another project's directory, `~` stays where it was and the device logs the conflict at startup until that project is removed.
- A project the user already added at the home path becomes `~` instead of a second row, keeping its id so its terminals stay put, and losing its configuration, running processes, tracked browser windows, setup state, notes, and review-comment drafts, since `~` has no surface to show or run them. A hidden project stays hidden. A project with more than one workspace, or one targeted by an automation, is left as it is, and that device has no `~` until the extra workspaces or automations are removed.
- Selecting `~` on the Mac while its panel holds no pane lands the user in a terminal: with no terminal running it opens a fresh one; with exactly one running it opens that one; otherwise nothing opens. Re-selecting the row or a background refresh opens nothing; coming back from Alerts or Automations selects it again. On an unreachable device, including one that drops while the terminal is opening, nothing opens and no error is raised, and a terminal that finishes starting after the user moved on is not brought forward.
- Selecting `~` while the Editor shows another workspace leaves the Editor where it is.

### Terminal sessions
- Every terminal runs in the built-in terminal, never an external terminal app. A workspace holds a process terminal (a configured process), a coding-agent terminal (a detected agent), and ad hoc terminals the user opens directly, which start in the workspace directory. Automation runs use built-in terminals too (see [Automations](#automations)).
- A session belongs to its device's daemon, not to any client: it survives the app quitting and reopens onto the same live shell.

### Names
- A name identifies each focusable target: browser sessions, processes, ad hoc terminals, and coding agents. A name is unique within its workspace across all four kinds, compared case- and accent-insensitively. A rename to a taken name is refused.
- Configured processes and browser sessions must have explicit names; there is no fallback to the command or URL. A `spaces.yaml` process or browser session without a name is rejected at import, naming the entry by its command or URL.
- A terminal's name does not move with its output: a process terminal takes its configured name, a coding-agent terminal the label the agent reports (`Coding Agent` when it reports none), and an ad hoc terminal a generic name (`shell-1`, `shell-2`, ...). What the program prints never becomes the name. An agent whose name is taken gets a numbered variant (`Coding Agent-2`). The row, its pane, and the palette use that one name.
- The title a program reports (for example `vim main.swift`) appears beside an ad hoc or coding-agent terminal's name as secondary text; a process shows its command instead. The command palette ranks a match on a name above a match on secondary text.
- Renaming an ad hoc terminal changes only its name. An empty rename restores the generic name it launched under, which stays reserved for it while it carries another name. An empty rename of a coding agent restores its reported name, or a numbered variant when another row took that name meanwhile. Renaming a configured process or browser session renames its workspace settings entry (a running process picks the name up on restart), and an empty rename there is discarded. Renames work the same from the Mac and iOS.

### Hiding
- Projects and workspaces can be hidden independently of whether they run. Hiding changes visibility and nothing else, on the Mac and iOS alike: it never stops a workspace or anything running in it and never asks for confirmation, so hidden work keeps running. Unhiding starts nothing.
- Hiding a project suppresses everything under it without touching its workspaces' own flags, so unhiding the project brings back exactly the workspaces shown before.
- A hidden row leaves every listing: the Mac sidebar and the iOS Spaces tab, the command palette, the Alerts pane and its badge, the session picker, and the project choice when creating a workspace. Dismissed alerts stay dismissed across a hide and unhide. An automation targeting a hidden workspace stays selectable and runnable.
- Hiding tears down no open panel, and a panel left open keeps working, including its session picker's rows for its own workspace.
- The Workspaces dialog (Mac) and sheet (iOS) list everything, hidden rows included, and are the only place a hidden row comes back. The hidden state is the device's, so a row hidden on one client is hidden on every client.

## Devices and Pairing

### Device management
- A device's default name is its machine name. Remote devices can be renamed from either client; the local device cannot be renamed or removed.
- Removing a paired device deletes only this client's pairing and credential. The device's projects, workspaces, and running terminals stay on it and keep running; pairing again brings it back.
- Restart Local Daemon asks first whenever any terminal session is live, because the restart stops every terminal, process, and coding agent on this Mac (the daemon's API can be down while its terminals still run); with nothing live it restarts without asking.

### Pairing and connections
- Pairing grants the client full control of the daemon. Every connection is pinned to the identity seen at pairing and carries a per-client token; a device presenting a different identity is refused before any authenticated request.
- `spaces device pair` with no argument opens a short-lived, one-time pairing window on this device and prints a `spaces://pair` link. The Mac can show a pairing QR code for any device it is connected to, so an iPhone can pair with a remote device through the Mac. iOS pairs from a `spaces://pair` link or QR code and reconnects on later launches without asking.
- A pairing link lists the device's addresses, local network first, then Tailscale. Every client (iOS, Mac, CLI) tries them in that order and stays on the first that answers; when none answer, the error points at Tailscale. A client goes straight to the address that last worked, a broken connection tries all addresses again rather than the one that failed, and iOS prefers the local address again when it returns to the foreground.
- A client learns a device's current addresses on every connect, so a device that gains Tailscale after pairing becomes reachable over it without pairing again.
- Pairing is version-gated. The link carries the daemon's wire-protocol and app versions; a client refuses an incompatible link before consuming the one-time window, the daemon refuses a client on a different wire version before checking the code, and the message says which side to update.
- Pairing the same device again updates its existing entry instead of adding a second. The CLI and the Mac app share one per-profile client identity, device list, and credential store, so a device paired from either works from both.
- Only a pinned-identity rejection or a refused token calls for pairing again. Any other connection failure (a stalled or reset handshake, a captive portal, a stored address that belongs to another machine) is a retryable outage. When a device does call for pairing again, iOS shows a notice and opens Paired Devices once per episode, keeps the stored credential, and keeps polling, so a rejection that was really a network problem clears on the next successful poll. The Mac reads a remote device whose stored credential is gone as "Reconnect required" whether or not it answers, with no reconnect action: pairing again is what recovers it.

### SSH
- Pairing over SSH (the Mac's add-remote-device form, or `spaces device pair --ssh`) never prompts: SSH must work with key-based auth and a host key already in `known_hosts`. It runs the device's own `spaces device pair --json` and pairs at the host SSH actually resolves to.
- An Ubuntu 24.04 device without Spaces is installed over SSH as part of pairing, with no second step. A failed install reports the failure and the exact install command to run on the device by hand. A remote Mac cannot be installed over SSH, so pairing one without Spaces fails with guidance to install the app there.
- SSH is needed only for pairing, remote browser sessions (an SSH local forward), and opening a remote workspace in an external editor. Remote terminals use the paired connection and never need SSH.
- An external editor opens a remote workspace over SSH as a local window, and reopening it focuses that window instead of opening another. When VS Code lacks its Remote-SSH extension, Spaces offers to install it first. The built-in Editor needs no SSH. Reveal in Finder works only for workspaces on this Mac.

### Unreachable devices (Mac)
- The Mac lists every paired device at once, and each loads independently: a slow or unreachable device, including this Mac's own daemon, never blocks the others.
- An unreachable device keeps everything it last reported: its projects, workspaces, runtime targets, and alerts stay listed (dimmed, alerts still counted in the badge), a selection under it stays selected, and its open panes stay open. An outage never moves the user elsewhere or empties the sidebar.
- An unreachable device can be browsed but not acted on. Anything that needs its daemon (workspace lifecycle, hide, delete, running or stopping targets, renaming, creating a workspace, saving settings) is unavailable. An already-open pane stays focusable; opening a pane for a target that is not open is refused, rather than leaving a dead pane that would not recover. An action reached by shortcut is refused with a message naming the device as offline and saying how to recover (reconnect a remote device, restart this Mac's daemon).
- Recovery is automatic: the Mac keeps re-checking every device that is not loaded, this Mac included, retrying less often the longer one stays down, and a network change (joining or leaving a network, wake, Tailscale up or down) reconnects at once. The device's Reconnect (Restart for this Mac) retries immediately instead of waiting out the backoff. Reloading is never needed.

## Mac App Launch and Quit

### Launch
- Launch runs a setup flow before the workspace UI, showing only pending steps: the Chrome Automation permission, then coding-agent hooks (see [Coding-agents setup step](#coding-agents-setup-step)), then the offer to restore coding-agent sessions (see [Session restore](#session-restore)). With nothing pending the flow is never seen.
- The Chrome Automation permission is the only blocking prerequisite (Spaces focuses browser sessions by scripting Chrome); there is no Accessibility requirement. While it is undecided or denied, launch blocks on a screen that requests it and advances on its own the moment access is granted, including when it is granted in System Settings. When macOS refuses to show the prompt because of a stale permission record from another Spaces build, the screen explains how to reset that record.
- When Chrome is not installed or the permission state cannot be read, launch does not block; the macOS prompt appears the first time a browser session is focused.
- Installed builds share one profile under `~/.spaces/`; repo-local development builds get one profile per git worktree.
- Terminals need no external terminal app, repository checkout, or terminal-specific environment variables.
- A second app instance for the same profile exits at once, naming the process that owns the profile.
- If the account's home directory cannot be read from the system account record, the app exits before showing a window with one line naming the cause. It never substitutes another location for the machine-wide desktop-control lease, because two processes each holding their own lease is worse than failing.
- An instance of a different profile, launched while another instance holds desktop control, still loads its data and windows but runs passive: in-app shortcuts only, with a status saying global shortcuts are unavailable.

### Quit
- Quitting with live sessions asks: keep them running (the default), Stop All and Quit, or cancel.
- Stop All and Quit cleanly stops this Mac's daemon work only, never a remote device's: workspaces stop normally, configured processes return to not started without exited alerts, ad hoc terminals (and any coding agent in one) are removed, home-project terminals are stopped one by one, and tracked browser tabs close without touching other tabs. If the clean stop fails, the user chooses Force Quit or Cancel Quit.
- Closing the main window hides it; Spaces, its shortcuts, panel windows, and background work keep running.

## Projects

### Adding a project
- A project comes from a folder or a git URL, created on one chosen device. An unreachable device cannot be chosen.
- A folder is validated on the chosen device, which also reads any `spaces.yaml` in it; folder suggestions come from that device's filesystem, so a project can be created on a remote device by path.
- For a git URL, Spaces reads only `spaces.yaml` from the declared default branch, without cloning, so the user can review the configuration first. The clone happens only at Create (an app-managed clone plus a default worktree on the default branch), so canceling leaves nothing behind. The created project uses the settings as the user left them in the form, not a fresh read of `spaces.yaml`.
- If the managed clone or worktree folders for that URL already exist but belong to no project or workspace, Create replaces them only after the user confirms.

### Project settings and `spaces.yaml`
- `spaces.yaml` is imported and exported from project settings only (there is no CLI for it). It lives in the project's default workspace directory: for a cloned project, the default worktree, not the bare clone.
- Export writes the saved project template as a complete `spaces.yaml`, overwriting the file, and is refused while settings have unsaved edits.
- Import only previews: nothing is persisted until Save, and the preview can be discarded back to the saved template.
- Saving a git project's settings changes the project template only. Existing workspaces, the default one included, keep their own settings unless the save carries an imported configuration and the user chooses to apply it to every workspace.
- A non-git project's template and its single workspace's settings are one: every save or import applies to that workspace, so the edits are what runs, and the choice is never offered.

### Deleting a project
- Deleting a project removes it and every workspace in it, the default workspace included, with their records and Spaces-managed worktrees; a project Spaces cloned also has its clone deleted, while a folder the user added stays on disk.
- The project's automations are deleted first, then its workspaces are torn down. If the teardown fails, the automations stay deleted; this is accepted.

## Workspaces

### Creation
- Creating a workspace is always explicit about project and branch (there is no import command), because it creates daemon state, allocates ports, and can run setup.
- A git workspace needs an explicit branch choice. Create branch rejects a name that already exists locally or on the remote; Use existing is the only way to attach to an existing branch (the Mac form, `spaces workspace create --existing-branch`, and MCP). A created branch starts from the chosen base branch (default: the project's default branch, else `main`, else `master`); a workspace on an existing branch records no base branch.
- A branch belongs to at most one workspace in a project. Deleting a workspace frees its branch and checkout directory for immediate reuse, and a workspace whose worktree went detached does not block another workspace from taking its branch.
- The checkout directory name is generated, never conflicts, is independent of the branch, and cannot be edited.
- A non-git project cannot create another workspace, and the home project never creates one.
- Creating a workspace finishes, and selects it, as soon as its record and directory exist; the setup script then runs in the background with its progress in the workspace's setup screen.
- On iOS, creating a workspace takes only a branch name and always creates that branch from the project's default branch; attaching to an existing branch is not offered, and a non-git project cannot create one there.

### Workspace settings
- A workspace's launch settings stay editable after creation, and its settings show the environment every process and terminal in it receives, with the values the owning daemon computes. For a remote workspace whose service is forwarded to this Mac, the port reads `<remote port>:<local port>`.
- Editing settings while the workspace runs never starts or stops browser sessions or coding agents. Name and on-exit edits apply to running processes at once; a command edit asks before restarting the affected processes, and cancelling leaves the configuration unchanged. Added rows appear at once as not running.
- App-level configuration is changed in the app only, never through the `spaces` CLI.

### Start, Restart, Stop
- Launch starts the workspace's configured processes and nothing else. Browser sessions stay unopened until the user focuses one, and no coding agent starts: an agent exists only when an agent command runs in a terminal.
- Unopened browser sessions, and configured processes that were never started or that the user stopped, stay directly openable and never degrade runtime health, warn about a missing window, or raise an Alerts item.
- Start (in the app, on iOS, or `spaces workspace start`) is convergent: it launches the configured processes that are not running, restarting failed or exited ones, and leaves running processes, ad hoc terminals, and coding-agent sessions alone. A workspace whose configured processes all run succeeds as a no-op.
- Lifecycle controls offer only what applies: Start whenever the workspace is stopped or any configured process lacks a live run (so a workspace running only ad hoc terminals or agents can bring up its processes without Restart's full reset), and Restart and Stop whenever it is running.
- Restart (in the app, on iOS, or `spaces workspace restart`) is a full stop followed by a fresh launch. The stop ends every tracked runtime, ad hoc terminals and coding-agent sessions included. Each configured process's pane is held for its replacement (see [Panes and tabs across a stop or restart](#panes-and-tabs-across-a-stop-or-restart)).
- Stop ends the workspace's processes, terminals, and coding agents and runs its stop script. Browser-session tabs are closed by the Mac app, not the daemon (see [Panes and tabs across a stop or restart](#panes-and-tabs-across-a-stop-or-restart)). Stopping or restarting never closes an unrelated window.
- Stopping or restarting a workspace cancels its active automation runs.
- A start or restart from outside the app (CLI or MCP) never moves focus in the Mac app: a launched process without a pane gets one on an unselected tab, an existing pane stays where it is, and nothing is selected, fronted, or focused, including when a terminal finishes connecting seconds after the command returned. Reason: a script or agent starting a workspace must not take the window the user is working in. In-app actions, `spaces terminal show`, and `spaces://terminal/<session-id>` links do bring the terminal forward.

### Setup
- Launch waits for workspace setup. Until setup succeeds, configured processes and browser sessions never launch or recover; the workspace offers setup recovery (retry, and editing the setup script after a failure) and ad hoc terminals for repair.

### Services and routing
- A project declares named services. A service name is a DNS label (lowercase letters, digits, and hyphens; starts and ends with a letter or digit; at most 63 characters) and is unique within the project, because it becomes a hostname and variable names. An invalid name is rejected rather than coerced (the GUI trims and lowercases what is typed, and an invalid name blocks saving). Each service gets one dynamically assigned local port per workspace.
- Every workspace process, terminal, setup script, and stop script receives:
  - `SPACES_<SERVICE>_PORT`: the assigned port, with the service name uppercased and hyphens turned into underscores (`admin-ui` is `SPACES_ADMIN_UI_PORT`).
  - `SPACES_<SERVICE>_HOST`: the routed hostname `<service>.<slug>.localhost`, without scheme or port, for framework host allowlists.
  - `SPACES_<SERVICE>_URL`: `http://<service>.<slug>.localhost:7391`, to reference instead of composing a URL.
  - `SPACES_WORKSPACE_SLUG`: a DNS-safe per-workspace label plus a stable hash, such as `login-fix-a3f9c2d1847b`. The prefix is the branch for a git workspace, the project name for a non-git one, and `home` for the home project's workspace.
- A local router on the Mac serves `http://<service>.<slug>.localhost:7391` for every assigned service, whether or not it has a browser session. The port is fixed with no setting; routing is plain HTTP on loopback only and needs no TLS, certificate, or admin setup, because Chrome and Safari treat `*.localhost` as a secure context. Firefox is unsupported: it does not resolve arbitrary `*.localhost` names.
- Routes target `localhost:<port>`, so a service may bind either IPv4 or IPv6 loopback.
- Remote and Linux daemons run no router. For a running remote workspace with services, the Mac forwards each service port over SSH and serves the same URLs through those forwards, opening the forward on demand when a remote browser session is focused. Remote processes receive `SPACES_<SERVICE>_URL` so servers can allowlist the browser-facing host.
- Port assignments belong to the workspace until it is deleted. Adding a service reserves its port immediately; stopping a workspace never gives its ports to another workspace.
- A stopped workspace's service ports are held by placeholders so nothing else claims them; starting any runtime in the workspace releases them so its servers can bind. While it runs, its ports are not held, and another process that grabs one first is the user's to resolve.

### Deletion
- Deleting a workspace stops everything it runs, removes its git worktree, and deletes its record with its settings, notes, port assignments, and the automations that target it (with their run history). Nothing is kept to restore. A default workspace cannot be deleted; deleting its project removes it. Deleting works the same from the Mac and iOS.
- Deleting the local or remote branch is optional (both off by default) and independent of the removal. `main` and `master` are never deleted. The delete reports only when requested branch deletion did not happen: a protected branch, no recorded branch, or a git failure. A branch that was already gone counts as deleted. When the connection drops mid-delete and the workspace is confirmed gone but the report was lost, a requested branch deletion is reported as unknown rather than passed over.
- A workspace being deleted stays listed, marked and inert, on every client, whichever client or project delete started it, until its daemon confirms; then it leaves once. A failed delete restores the row and reports the error. This keeps a refresh mid-delete from making the row flicker back.
- Deleting never blocks other workspaces or devices. Deletes on one device run one at a time in the order requested; deletes on different devices are independent. On iOS, switching device cancels a delete still waiting its turn, with a notice to delete it again from that device.
- Ended sessions of a deleted workspace never appear: no loose terminal group and no alert.

### Discovery
- Each daemon scans its git projects' worktrees when it starts and whenever a project's git worktree metadata changes. A worktree on a named branch with no workspace becomes one automatically, with the project's settings and its setup script; a worktree on a detached HEAD is not imported.
- A non-default workspace whose worktree is gone is deleted the way Delete removes one. A checkout directory still on disk keeps its workspace even when git omits it from the worktree list, and a git probe that fails retires nothing.
- Delete removes the worktree, which is what keeps it from coming back. A valid worktree still at that path (one the delete could not remove, or one made there later) is live work and is imported again. Hiding, not deleting, is how an existing worktree stays out of view.
- A workspace whose worktree goes detached keeps its record and last branch name. When the worktree returns to a branch, the workspace takes that branch. When another worktree of the project holds the last branch first, that worktree owns it and the detached workspace's branch is cleared.

## Terminal Sessions

### Opening and ownership
- Opening a terminal never restarts its shell: a pane attaches to the existing session, local or remote. The pane appears at once in a preparing state with input disabled, never waiting on a remote device's credentials, and becomes live when the session is ready; a session that fails to start shows as failed and cannot be acted on.
- A session has at most one owner client and any number of viewers. Only the owner sends input or resizes; stale owners and stale resizes are ignored.
- Opening a terminal on the Mac takes ownership only when no other client holds it (`spaces terminal show` takes it even then). Opening one on iOS, or returning to an open one from the background, takes ownership even from another active owner.
- A pane on a session another device owns names that device (or says no device owns it) and offers Take Over. It receives no live output and ignores typing.
- An owner that vanishes without disconnecting (crash, force quit, lost network) loses ownership within a bounded lease, on the session's own device too; the next client to attach or take over becomes owner.
- A client whose attachment the daemon dropped (a phone away past its lease, a Mac pane) reattaches on its own, with no prompt: it takes ownership back if no one else claimed it, otherwise it returns as a viewer.
- After a daemon restart, including an in-place update, every pane reattaches in the role it had; an owner whose session was taken over meanwhile returns as a viewer.

### Closing and ending
- Closing a process or coding-agent pane only detaches; the session keeps running and reopens on focus. Closing an ad hoc terminal's pane ends the session only when it sits at a bare shell prompt, holds no background or stopped job, and no other client owns it; otherwise the session keeps running and stays listed, so the user can come back and see how the program ended. This holds for closing a pane, a tab, or a whole panel window. Closing a viewer pane never ends a session, and neither does detaching or losing every client.
- Closing the pane of an ad hoc terminal whose session already ended removes its row.
- A session ends when its program exits or gives up the terminal (closes stdin, stdout, and stderr while still running); Spaces then stops that program rather than leave it running where no one can see or stop it.
- A session that ends keeps its pane, showing the final screen with a persistent read-only notice: "Session ended" for any exit, whatever its exit status, and "Session failed" only when the session failed to launch or its device lost it without recording an exit (for example after a daemon crash). Read-only means no input; scrolling back still works. Typing pulses the notice, the notice clears if the session runs again, and it stays while the device is unreachable.
- An ended pane stays open only while its runtime entry (the process, coding-agent, or terminal row backing it) exists; when the entry is removed, on any device, the pane closes. Otherwise panes and tabs close only when the user closes them. An exited target, of any of those kinds, opens its pane in its ended state.
- Ended sessions are kept for seven days after they end, then removed with their rows, saved panes, and transcripts. When a device's retained ended-session data passes 2 GB sooner, the oldest-ended go first. Neither bound is configurable.

### Configured processes
- A configured process has one current session shared by every client. Launch, focus, and restart reuse it, so neither the Mac nor iOS ever shows two instances of one configured process. Its row stays listed after the process exits so the final output can be opened.
- Stopping a target ends its session and removes its pane. Restarting a target keeps its pane: the replacement session takes the same tab and split position, whichever client asked, so an exited pane never sits beside its running replacement. Starting a target whose last run exited reuses that ended pane the same way. Starting never removes a pane.
- Starting one configured process never raises Alerts for sibling processes that were never started or were stopped.
- An exited terminal kept open by its on-exit setting keeps its final screen and can still be stopped; a kept-open exited configured process can also be restarted.
- Every command Spaces runs in a terminal (configured processes, `spaces terminal create --command`, spawned coding agents, script automations) runs as a shell command string inside the user's interactive login shell, so it resolves exactly what it resolves when typed into a Spaces terminal: PATH, version managers, and full shell syntax.

### Input and output
- Personal Ghostty configuration never affects Spaces terminals; they use the Spaces theme, and an appearance change updates open terminals.
- Sessions identify as `xterm-ghostty` with its terminfo installed. Programs get answers to terminal capability, size, and color-scheme queries whether the session is local or remote. A headless Linux session identifies as a VT220-compatible ANSI-color terminal, reports its exact grid, uses one synthetic pixel per cell for pixel queries, and reports the appearance of the client attached to it.
- A key reaches the program with its modifiers, encoded for the keyboard mode the program asked for, identically for local and remote sessions: `Shift+Enter` inserts a newline in an agent using the Kitty keyboard protocol while `Enter` submits, and arrows follow application cursor mode. `Shift+Enter` does not submit a line in an ordinary shell.
- Text paste uses paste semantics, so a bracketed-paste-aware program receives multiline text as one paste.
- Image paste on the Mac: `Cmd+V` or `Ctrl+V` with an image on the clipboard uploads it to the device hosting the session, saves it under `/tmp` there, and pastes that path. TIFF becomes PNG; images over 10 MiB are refused. Without an image, `Cmd+V` pastes text and `Ctrl+V` is terminal input.
- A program's clipboard copy (OSC 52, OSC 5522) goes silently to the clipboard of the device that currently owns the session, never to other viewers; with no owner it is discarded. Copies over 1 MiB are refused. A program reading the clipboard gets the host Mac's clipboard in a Mac-hosted session; a Linux-hosted session cannot read one.
- Text size on the Mac: `Cmd+=` and `Cmd+-` (shift optional) step one point between 9 and 18 points, starting at 12; there is no reset. One size applies to every open pane, persists per profile, and reflows live sessions. On iOS, terminal text is 9 to 12 points (default 10), saved per device, and a change reflows open sessions.
- A link opens only on the device where the user activated it, never on the session's host. On the Mac, web links and HTML go to the default browser; images, video, PDF, Markdown, and text to their default app. A local session's file link opens any file, resolving relative paths against the session's live working directory. A remote session's file is fetched to the Mac first (cancellable), so an HTML file's sibling assets do not load. A loopback address printed by a remote session shows a notice, on either client, that it is not reachable from this device.
- A plain-text URL that wraps across rows stays one clickable link in live, remote, and ended panes.

### Scrollback, mouse, and taps
- Scrolling back reads the viewer's own copy of the session's history, in every Mac pane, every ended pane, and on iPhone and iPad: the session's viewport never moves and its screen keeps updating underneath, so another viewer of the same session is unaffected. Scrolling past the oldest row the viewer holds fetches the rest of the retained history once. Typing returns the view to the live screen (on iOS, so does switching light and dark). A session showing a full-screen program or tracking the mouse gets the wheel and every swipe instead.
- The jump-to-bottom control appears whenever a view leaves the last row, and marks when output arrived below. A jump on the session's own viewport moves every viewer; a jump in a view reading its own copy moves only that view.
- A click inside a program that tracks the mouse (vim with mouse on, htop, tmux, lazygit) reaches the program. Shift+click selects text instead. Cmd+click opens a link locally and is never forwarded, because a mouse-aware program would read it as a plain click on the same link and open it a second time on the session's host; Cmd+Shift+click follows a link while a program holds the mouse. A program that asks to capture Shift (XTSHIFTESCAPE) keeps Shift-clicks.
- On iPhone and iPad, a tap on a link opens it on the device and reaches the program as nothing. While a program tracks the mouse, any other tap is a click at that cell and leaves the keyboard alone; otherwise, or while scrolled into history, a tap focuses the keyboard. A tap opens a link only while the phone shows the session's full width, so a link cut off by the brief cropped view after an open or takeover is never opened partially.

### Shared selection
- A terminal has exactly one text selection, owned by the session's host and shown to every viewer. It is anchored to the text: output carries it up into scrollback rather than clearing it.
- Copying copies the whole selection even where it has scrolled out of view. A new selection replaces the old one for everyone; a plain click in any viewer clears it for everyone (also when a mouse-tracking program takes that click), while Shift+click extends it. Once the selection has scrolled wholly out of a viewer's screen, a click or tap there only focuses and leaves the selection alone.
- A drag stays local to the dragging pane until release, which commits it for everyone and copies it to that Mac's clipboard. A drag is canceled, never guessed, when a resize reflows the text under it or output moves more than a full screen between two frames. A committed selection follows its text through a resize, or clears for everyone when the resize removes its anchors.
- iPhone and iPad show the shared selection and can copy it in full or clear it; they cannot create or adjust one. An ended session keeps its highlight in the final frame, but copying and clearing are unavailable there.

### Connection loss
- These rules hold for Mac panes and the iOS terminal alike. A terminal whose device stops answering stays open showing the last frame. After one second without the stream it shows "Reconnecting…" (a blip that heals within the second shows nothing); once every known address for the device has failed it shows "Device unreachable" with Retry, immediately. Any sign of life clears both, and so does learning the session ended.
- While unreachable, Spaces redials on a lengthening schedule up to 15 seconds apart, starting a fresh attempt each time even if an earlier one is still hanging, and paints from whichever answers first. Retry redials at once and restarts the schedule.
- Typing, scrolling, or resizing a view that cannot reach its device raises the notice rather than leaving it looking live. Typing is never held back by the notice.
- A send that fails outright (refused, closed, or every address unreachable) marks the device unreachable and discards what was typed with anything queued behind it, so a command the user gave up on is never replayed later, and it does not push out the next scheduled retry. A send that only times out is checked with a ping first: if the device answers, nothing is shown and typed keys keep flowing. Queued input survives that check either way, and a flapping link keeps its queued input by design. Input the device refuses for its own reasons (session not running, another client owns it) says nothing about the connection.
- A connection that dies silently (socket open, nothing arriving) recovers within about ten seconds, on iOS and in Mac panes for remote sessions.
- On iOS, the app's own connection-error alert waits until the terminal is left.

## Mac Panels and Focus

### Panels, tabs, and panes
- A workspace's panel holds only terminal sessions; the Editor never lives in it.
- `New terminal` always opens a fresh ad hoc terminal as a tab in the selected workspace's own panel, even while a panel window is focused, since panel windows hold no tabs of their own. Repeating the action while one is still opening starts no duplicate.
- Splitting or adding a tab offers a fresh ad hoc terminal plus the workspace's targets not already open in any pane; browser sessions are never offered. Picking an exited target opens its ended pane; picking a not-started process starts it; either lands at the picker's placement. A panel window's picker lists targets from every loaded device. Picking a row or cancelling returns focus to the pane the picker was opened from, in that pane's own window.
- Switching workspaces restores that workspace's selected tab and focused pane. Tabs, panes, splits, focus, divider positions, tab order, and custom tab names persist across relaunch, reattaching to sessions still alive and dropping panes whose sessions are gone.
- A tab is named after its selected pane and a panel window after its selected tab, so moving focus within a split renames both; a tab never shows the program's live title. Clearing a custom tab name returns it to the derived name.
- A pane that closes because its session ended (stop, restart, exit, or its device stopped tracking it) leaves the caret where it is. A pane the user closes moves the caret to the pane that takes its place.

### Panel windows
- A terminal pane can move into a panel window: a separate window not tied to one workspace, whose splits may mix sessions from any workspace or device. It holds one tab's worth of panes and has no tabs of its own.
- Moving a session to a panel window moves it, never copies it. A tab moves with all of its panes; a single pane can move out of a split on its own. The Editor is never moved this way, since recreating it would lose its unsaved buffer.
- Closing a panel window's last pane closes the window. Sidebar clicks, numbered shortcuts, and the palette focus a session wherever its pane lives.
- Panel windows and their frames persist across relaunch and reopen once their devices connect, dropping panes whose sessions are gone; a window with nothing left does not reopen. A saved panel window that held several tabs reopens as one window per tab, losing no pane.

### Panes and tabs across a stop or restart
- Stopping or deleting a workspace from the Mac closes its terminal panes and its tracked browser-session tabs once the owning daemon confirms. Tabs are matched by the workspace's session URLs, so no other tab or window is touched. The Editor stays open through a stop or restart of the workspace it shows.
- A workspace restart keeps each configured process's pane in place (tab, split position, window) for its replacement session when the restart comes from iOS, the CLI, or MCP. A process whose pane was closed before the restart gets a fresh unselected pane, a process whose relaunch fails has its held pane closed, and ad hoc terminal and coding-agent panes close with their sessions. A workspace restart started in the Mac app closes all of the workspace's panes and its tracked browser tabs instead.
- When another client stops a workspace, the Mac closes its panes, and closes its tracked browser tabs once it sees a workspace on this Mac's own daemon stop. A stop of a remote device's workspace made from another client leaves this Mac's tabs open, as can another client's restart that the Mac never sees as stopped. With no Mac app running, the tabs stay open, because only the app tracks them.

### Sidebar
- Under a project, the default workspace comes first, then the rest by name (natural, case-insensitive).
- A workspace's targets are grouped in a fixed order: browser sessions, configured processes (running or not), coding agents, then ad hoc terminals. The numbered target shortcuts follow the same order, so a row's position and its number never disagree.
- Each managed target carries a state (working or running, blocked, done, inactive or not started, exited), and a workspace shows its highest-attention target's state even while collapsed, in the priority exited, blocked, done, working, idle. Ad hoc terminals and browser sessions carry no state.
- Project rows remember their collapsed state across relaunch; workspace rows start collapsed after every relaunch.

### Focus
- Focus acts on one target (a terminal pane or a browser-session tab) and never runs a workspace Launch or Restart: a live target is focused, and a configured target that is not live is opened or started directly. Opening one in a stopped workspace moves the workspace out of `Stopped`.
- Clicking a sidebar target, its numbered shortcut, and its palette row do the same thing: a terminal-backed target focuses or opens its pane, a browser session its Chrome tab, and a not-yet-running configured process starts and opens.
- A focus or open request that arrives before the app has caught up with a just-created workspace or a just-started process waits for the app's next refresh and then completes; a target still absent after that refresh is genuinely absent, and the request is dropped.
- Focusing a target, or opening an external one (browser session, Finder reveal, preferred editor), leaves Spaces visible; the target app comes forward on its own.

### Browser sessions
- Browser sessions open in Google Chrome only. Focusing one with Chrome closed launches Chrome. When Chrome cannot be scripted (not installed, or Automation permission denied), focus shows an error naming Chrome, and the denied permission when that is the cause, instead of opening another browser. That failed focus is not remembered as the workspace's last focused window, and from the command palette it counts as a cancelled selection.
- A session is matched by URL, never by window title. Focus tries the session's tracked Chrome tab, then any Chrome tab with a matching URL (adopting it, so a tab the user moved by hand keeps working), then opens a tab in an existing tracked workspace Chrome window, then a fresh window.
- A tab matches when it shows the session's URL exactly (a trailing slash aside) or a page under it. An exact URL beats a prefix match, and prefix matching never picks a longer sibling session's URL. Hosts compare exactly, so `google.com` and `www.google.com` are different sites. A tab on a service's routed URL also matches a session configured on that service's loopback port.
- Only the session's Chrome window comes forward, switching the desktop Space or restoring it from the Dock as needed; Chrome's other windows keep their stacking so none covers Spaces.
- Spaces never polls for browser-session windows. It validates on focus, and a stale session is adopted or reopened silently, with no error.

### Refresh and progress
- A workspace or project operation's progress shows only while that workspace or project is selected, so it never blocks actions on another one; returning while it is in flight shows it again.
- Background refreshes update in place without replacing the detail pane or resetting the selected workspace tab. Open dialogs (New Project, New Workspace, project settings) survive every refresh, including a device going offline or incompatible, its recovery, a failed reload, or the workspace being deleted elsewhere; only the user moving the detail pane to other content dismisses them.
- A refresh that cannot resolve the selected workspace (its daemon restarting or unreachable) leaves the pane as it is. A workspace the answering device does not list (deleted from another client) resolves to the neutral placeholder.

## Mac Shortcuts and Navigation

### Shortcuts
- Spaces' own shortcuts are configurable in Settings: the global shortcuts, the shortcut leader and its chords, and the direct-focus modifier. Standard macOS keys are fixed, such as `Cmd+W` (close the focused pane) and `Cmd+X` (dismiss the selected alert in the palette, unless the search field has text to cut). The text-zoom keys are fixed too, but assigning one to a configurable shortcut takes it; `Cmd+0` is not a zoom key.
- The shortcut leader must contain at least two modifiers. A refresh that fails to read the stored shortcuts keeps the chords in effect, so no shortcut ever drops to a bare letter.
- With a terminal focused, non-`⌘` keys belong to the terminal. `⌘` shortcuts and configured leader shortcuts run app actions first; an unclaimed `⌘` shortcut falls through to the terminal's own `⌘` bindings, and an unclaimed leader chord to the terminal. Shortcuts never break normal text editing while an input is focused.
- The app toggle (default `Cmd+Opt+=`), the command palette (default `Cmd+Opt+-`), and next and previous window cycling work with any app frontmost. The cycle-mode chord works only while Spaces is active.
- The app toggle hides the whole app, panel windows included, when the main window is focused, returning focus to the other app that was frontmost when Spaces was summoned. Otherwise it shows Spaces with only the main window raised, onto the active Space.
- When summoned, Spaces selects the workspace owning the window or terminal pane focused just before; otherwise the view stays on the pane already visible.
- The palette shortcut concerns only the palette: showing it neither fronts panel windows nor hides the main window. Dismissing it without a selection returns focus to the window active before it opened.
- Only leader+Up and leader+Down move the sidebar selection; plain arrow keys never do. They work while a terminal pane has keyboard focus, and a matched chord is consumed at a list edge so it never reaches the terminal.

### Command palette
- The palette draws from every navigable target across workspaces: browser sessions, processes, ad hoc terminals, and live coding-agent terminals. An empty query shows Alerts items first, then the most recently focused targets, up to nine rows, falling back to target order with no focus history. A typed query fuzzy-matches project, workspace, target name, and detail, including across fields (`fu` matches `Frontend` plus `URL`). Enter runs the same action as the target's numbered shortcut.

### Numbered shortcuts
- The direct-focus modifier plus `1` through `9`, and `0` for the tenth, focuses the selected workspace's targets in sidebar order: browser sessions and configured processes in saved settings order, then coding agents, then ad hoc terminals. Configured targets come first so their numbers never move as agents and terminals come and go.

### Window cycling
- Next and previous rotate over the current mode's set in most-recently-focused order. A run of presses walks a frozen snapshot, so it covers the whole set and wraps at both ends, and a target whose state changes mid-run keeps its place. Typing or clicking in the landed target ends the run. Cycling always means window cycling, even with the main window focused.
- The mode shortcut steps Workspace, Alerts, All agents, Open sessions, then wraps. The mode persists across launches; an unrecognized stored mode reads as Workspace.
  - Workspace: the already-open windows of the workspace resolved from what is focused: browser sessions whose URL is present in their tracked Chrome window, and process, ad hoc, and agent targets with an open pane, including a pane left open at the last quit on a reachable device. Unopened sessions, unstarted processes, and sessions without a pane are skipped. When two workspaces configure the same URL and one Chrome window holds both, the rotation's remembered position decides.
  - Alerts: every Alerts item on any device that has a window to land in, most recent first. Failed automation runs and alerts whose terminal is gone are left out. A dismissed alert leaves the rotation; landing on an alert does not dismiss it.
  - All agents: coding agents on any device that are launched and not exited, idle included, most recent state change first.
  - Open sessions: every open pane and every browser session reported open, on any device, by visit recency; targets not visited this launch follow in sidebar order.
- Modes other than Workspace span every paired device, and landing on a target selects its workspace. Alerts and All agents leave out rows on an unreachable device unless their pane is on screen (a pane only saved in a layout does not count). Open sessions leaves out an unreachable remote device's browser sessions but keeps its open panes, and keeps the local Mac's browser sessions even while its daemon is down.
- Cycling an empty set does nothing: no window changes and the mode stays.
- Clicking or typing in a pane counts as visiting it. Visit order lasts for the app's life; a fresh launch cycles in sidebar order.
- With no Spaces terminal focused, a press starts from Chrome's front tab, even when Chrome is not frontmost.
- Cycling and the mode's window count never launch Chrome; with Chrome closed its sessions count as not open. The count refreshes on events, never on a timer.

## Editor

### Editor window
- The Editor lives in one global window, never in a workspace panel, and at most one exists.
- It follows the sidebar's workspace selection, restoring the target workspace's own saved state. Reopened at launch, it shows the workspace and state it last showed, and follows the sidebar again only once the selection changes.
- It closes only when the user closes it or quits. When its workspace is deleted, it retargets to the workspace Open Editor would pick, or closes if no workspace remains on any device.
- Open Editor (default `⌘⌥E`) targets the workspace of the focused tracked Chrome tab, else the selected workspace (while Spaces is active), else the workspace most recently active on this Mac; with none, it does nothing. The sidebar's and palette's Open in Editor target their own workspace.
- The editor preference picks the built-in Editor (default) or an external editor (Zed, VS Code, Devin Desktop) opened on the workspace directory.
- A workspace with no saved Editor state opens in Diff when its project is a git repository and in Editor mode otherwise. A non-git workspace opens in the Editor like any other, where the Files tree and quick-open are its only way to open a file; it has no comparison: Diff says "Not a git repository", and the sidebar holds only the Files tree.
- Editor state is kept per device and workspace (mode, scope, layout, selection, tree expansion, scroll and focus, unsaved buffers, review-comment drafts, the assigned agent, an agent launch in progress) and survives switching workspaces, hibernation, relaunch, and daemon refresh.
- If the page behind the Editor stops, the pane says so and offers Reload, which restores the saved state.

### Diff
- Diff compares the working tree against a scope: uncommitted changes, the last commit, the workspace's base branch (offered only when one is configured, falling back to `origin/<base>` when only that resolves), any branch, or any commit or ref. A typed ref is used as written; a bad one fails in the diff, not up front.
- The diff live-updates as the working tree changes, and so do the Files tree and quick-open as files are added, removed, or renamed. Diffs are never truncated, however many or large the files, locally or remotely.
- When the device loses the ability to watch the workspace's files, the Editor keeps working on what it last loaded and says live refresh is off, with Retry; on Linux the reason includes the advice to raise the inotify watch limit when that is the cause.
- A git submodule appears as a read-only pointer row naming the commits it moved between (marked dirty or unmerged when applicable), with its own changed files beneath it, viewable, commentable, and editable like the workspace's own. What those files show follows the scope. A submodule that is not checked out (never updated, missing the recorded commit, replaced by a symlink, or nested deeper than eight levels) shows nothing inside. The repository's `submodule.<name>.ignore` and `diff.ignoreSubmodules` settings are honored. An untracked nested repository is not listed.

### Editing and saving
- The new side of a diff, or an open file in Editor mode, is editable one file at a time. Edits save themselves about 0.8 seconds after the last keystroke; `⌘S` saves at once. A failed save retries on its own, backing off from one second to 30.
- Every save checks the file against the version the edit started from. External changes that do not overlap merge in, with an undo until the next keystroke. An overlapping change, or a deleted file, blocks saving until the user keeps their version or takes the disk's.
- Switching to another file saves the current one first; if that save fails or is blocked, the switch is refused and the buffer stays.
- Quitting waits up to about two seconds for pending saves. A conflict-blocked buffer is not written; an edit made just before its pane hibernated is kept and written when the pane next opens.
- Inline editing refuses a path through a symbolic link, because a save must land on the exact file the diff names. In Last commit, a file is editable only while the working-tree file still matches the commit under review; otherwise the user is sent to Uncommitted.
- Open in Editor from a diff line lands on that line (a removed line lands on the next kept one). The caret does not move when the file has unsaved edits, or in Last commit once the file differs from the commit, since the diff's line numbers would be wrong.

### Files and previews
- The Files tree and quick-open list the workspace: for git, tracked and untracked files minus ignored ones, plus files inside checked-out submodules; for non-git, every file. A symlink is listed only when it resolves to a file inside the workspace. Files over the 10 MiB open limit are left out, and a listing stops at 50,000 paths with a note saying so.
- Some file types open in a rendered view with their source a toggle away: Markdown (split source and preview), JSON (a read-only tree), SVG (the image), CSV and TSV (a read-only table), and images. The chosen view is remembered while the Editor is open, not across relaunch. An image opens view-only, does not reload on disk changes, and is not restored after hibernation or relaunch; other binary files do not open.
- Previews are bounded, with a note naming the bound: Markdown to 5000 lines or 1,000,000 characters and to 200 images, 64 MiB encoded or 64 megapixels in total; JSON trees to 2000 members per container; SVG to 1,000,000 characters; tables to 200 columns, 2000 rows, and 50,000 cells. The source view always holds the whole file.
- A Markdown preview never fetches anything outside the workspace: workspace images render, others show their alt text, links to workspace files open them in the Editor, heading links scroll the preview, and every other link does nothing.
- A JSON tree shows numbers exactly as written, and a key written twice once, in its first position, holding the last value (what every JSON reader takes). A file that is not strict JSON, a `.jsonc` or `.jsonl` file, or one nested more than 512 levels opens as text only.

### Files tree actions
- Files tree rows offer New file, New folder, Rename, Move to, and Delete; Open in system viewer is offered only for a file the Editor cannot show as text, on a workspace stored on this Mac.
- A name is used exactly as typed (surrounding spaces kept); trimming only decides whether it is blank. A name with a repeated, leading, or trailing slash, or a `.` or `..` segment, is refused, since it would land somewhere other than the row shown.
- Nothing is ever overwritten: creating, renaming, or moving onto an existing path is refused. Any path through a symbolic link is refused. Renaming, moving, or deleting a git submodule checkout, or a folder holding one, is refused with a pointer to git, since moving the directory would break the repository's link to it. Delete always asks first, since a folder can hold entries the listing does not show.
- Renaming or moving the open file keeps it open at its destination, unsaved edits included.
- Every change reloads the listing from the device. When the device stops answering a move, the outcome is read from the next listing; in a workspace larger than the listing, the outcome is reported as unknown.

### Review comments
- In Diff mode, a comment anchors to a file, side, and line. Send delivers one comment at once; Send batch delivers every draft with text in one call, whether or not it was marked with Add to batch (marking changes only the card). An empty draft is never sent and disappears once it loses focus.
- A send delivers each draft's latest text, including text typed into a card that still has focus. Drafts persist across relaunch, hibernation, and diff refreshes. A refresh keeps a draft on its line when the text is unchanged, moves it to the nearest matching line when the diff shifted, or marks it outdated but still sendable. A draft whose file leaves the diff lives on in the batch tray. Only sending or deleting removes a draft.
- Sent comments are archived with no thread and cannot be browsed afterwards; the agent's next diff is the reply.
- Comments go to one assigned coding agent: the workspace's only running agent is assigned automatically, several running agents offer a choice, and sending is disabled while none is assigned and running. Start agent runs any command in a background workspace terminal and assigns the agent once its hooks report it; if the command exits or nothing reports in time, sending stays blocked.
- A comment reaches only a non-exited coding agent that still belongs to the workspace; a bare shell an agent left behind is not a destination, and a rejected send leaves the draft to retry or edit.

## Alerts
- Attention comes from exited configured processes, blocked or done coding agents, terminal bells, and failed or timed-out automation runs; iOS also lists terminals that exited or failed. An event without a timestamp is skipped, and a session shown by a configured row never alerts twice. A stopped workspace can still contribute.
- On the Mac, Alerts and the badge combine attention from every paired device; iOS shows the selected device's.
- A terminal bell raises an alert only when the user is not watching that session: not while its pane has keyboard focus on the Mac, and not while it is open in the iOS terminal viewer. Focusing a session does not clear an alert from a bell it rang earlier. Bells from one session within 30 seconds are one alert; a later bell raises it again.
- The badges (the Mac's Alerts and Dock badges, the iOS Alerts tab) count the visible items after dismissals.
- Dismissing an item hides it until that attention event changes (a later exit or bell alerts again). Dismissals persist across launches, on the Mac and per device on iOS. Dismissing never hides the process or agent row from the sidebar. A target row's Dismiss Alert dismisses every undismissed alert on that row.
- Dismissing an exited process's alert drops that row back to the not-started state on the client where it was dismissed, until the process exits again. Dismissing an agent or bell alert leaves the row's state alone.
- The Alerts pane opens only when the user asks for it, and at launch when nothing is selected. A refresh or an arriving alert never navigates to Alerts or replaces what is on screen.
- A failed or timed-out automation run's alert names the automation, the failure (with exit code when known), and the device. On the Mac it is grouped under its device and opens the Automations Runs view filtered to that device; on iOS it has no terminal to open.

## Automations
- An automation is a named task that lives on one device, targets one workspace there, and runs on demand or on a cron schedule. An agent automation spawns a coding agent (its command must launch claude, codex, or opencode and may carry flags) and seeds it with a prompt; a script automation runs its script at the workspace root in the device's login shell. The device is chosen only at creation.
- An agent automation's prompt is sent only once the agent is identified, reading input (bracketed paste on), and has stopped painting its startup. It counts as delivered only when the agent visibly starts working: an unconsumed prompt is sent again, and one left sitting in the composer is submitted. An agent that never becomes ready, or a prompt that cannot be delivered, fails the run within 90 seconds and leaves the session running for inspection.
- Readiness is about input, not screen content: a trust, onboarding, or sign-in dialog raised after the agent starts reading input can receive the prompt, and its Enter can answer that dialog. A first run of a freshly installed agent is better driven by hand or by an orchestrator.
- Live automation terminals appear among the workspace's runtime targets. Stopping one cancels its run. An ended automation terminal leaves the workspace, and its replay stays available from Runs.
- A run records its trigger: manual, cron, scheduled (a one-time next run), missed catch-up, or restore (brought back by session restore). A skipped run records why it was skipped.
- The concurrency policy decides a fire that lands while an earlier run is queued or running: Skip records a skipped run (the default when creating an automation), Queue holds at most one pending run until the current one ends, and Allow always starts another. For an agent automation, the previous run's agent session still being open counts as overlapping, since a done agent leaves its session open for review; closing that session or using End agents releases the gate. A cancelled or timed-out script stays overlapping until its process group has exited.
- The missed-run policy decides cron occurrences missed while the daemon was down: run once (one catch-up run however many were missed) or skip (one skipped run). Either way the next fire is recomputed from the present.
- An optional timeout ends a run as timed out.
- No automation ever kills a live coding agent on its own. History retention never removes a run whose agent session is still open.
- Cron schedules follow the device's current time zone, so a daily or weekly schedule keeps its wall-clock time after the device changes zone. Previews and one-time picks use the target device's time zone. A valid cron expression with no possible future occurrence is rejected.
- A one-time next run replaces only the next occurrence: after it fires, a cron automation resumes from its expression and a manual one returns to running on demand. The time must be in the future and the automation enabled; Run Now works even on a disabled automation. Saving an edit to the automation clears a pending one-time run, because the edit restates the schedule to keep.
- An automation's type (agent or script) cannot change while it has a queued or running run; every other field stays editable.
- Deleting an automation cancels its running run and ends any live agent sessions its runs left open.
- Coding agents a run spawns are attributed to that run; a finished run with a live attributed agent offers End agents to reap it. An agent that a script automation spawns on a different device is not attributed: run history stays with the automation's device.
- A run's terminal, and its spawned agents' terminals, stay replayable for as long as the run is listed (until retention prunes it or the automation is deleted), but the device's ended-session age limit and ended-transcript disk budget can still reclaim them; the replay then reports the render as unavailable.
- The Mac's Automations view and its running-run badge span every paired device; an unreachable device is shown as unreachable, not left out.
- iOS works with the connected device's automations: it can run one now, cancel a run, end a run's agents, open a run's terminal, and set a one-time next run, but creating, editing, and deleting stay on the Mac. A skipped or queued run never had a terminal. The Automations badge counts runs in flight; a failed run badges Alerts instead.

## Coding Agents

### Signals and rows
- `spaces agent signal <init|working|blocked|done|exit>` reads the workspace and session from `SPACES_WORKSPACE_ID` and `SPACES_TERMINAL_TRACKING_ID`, with `--workspace` and `--session` overrides. When neither source supplies both IDs it exits successfully and reports nothing; an explicit ID that leaves the pair incomplete fails instead, since a caller that names an ID meant to signal. It reports only from Spaces terminals and exits successfully anywhere else.
- An event that cannot be reliably attributed to a terminal is dropped, never guessed onto the frontmost window.
- `init` attaches to or creates the terminal's agent row. Other events update the existing row; with no row, one is created only when the terminal is known to run a coding agent.
- An ad hoc terminal becomes an agent row when its foreground process is a known agent command (claude, claude-code, codex, opencode). A terminal Spaces launched to run an agent shows as one as soon as the agent is identified, by hook signal or detection, never waiting on hooks: Codex fires none before its first turn, and broken hooks fire none at all.
- Once a row exists, foreground changes never relabel it. A row that has signaled, or belongs to a terminal Spaces launched for an agent, stays through a bare-shell moment and reads exited when its agent ends; a detection-only row that never signaled returns to a plain terminal when its agent exits.
- Detection only creates a row or resets it to idle; working, blocked, done, and exit come only from signals. A later `init`, or an agent detected again in the same terminal, resets an exited row to idle.
- An agent that exits while its terminal session is still live reads exited, so watchers see an exit and a held blocked notice is withdrawn. Once the agent's terminal session has ended, its row is removed, whatever kind of terminal it ran in; closing a pane ends no session, so it removes no row. Ending an ad hoc terminal likewise removes the agent row bound to it, even an exited one.

### Status
- working shows activity. blocked counts toward Alerts and Dock attention. done stays in Alerts and Dock attention until dismissed while the workspace row shows completion. idle and exited raise nothing and count as not active; exited means the agent process is gone but its terminal survives.
- A blocked agent returns to working when it resumes. opencode reports the permission answer itself, so its row leaves blocked the instant the prompt is answered. Claude Code and Codex report no answer and fire their pre-tool hook before the decision, so their rows leave blocked when the approved tool finishes, success or failure. Denying a Claude Code prompt ends the turn with no hook, so that row stays blocked until the next prompt.
- Repeated working signals from an agent already working are ignored and do not refresh the row's updated time, which marks when the agent entered its current status.

### Orchestration
- `spaces agent list` and `spaces agent status` (and the MCP tools `spaces_agent_list`, `spaces_agent_status`) show the device's coding-agent sessions, each with its brief's one-line summary rather than the brief itself (see [Briefs](#briefs)), failing when no matching session exists. `spaces agent signal` is CLI-only and never an MCP tool, so an orchestrator can read status but cannot forge another agent's.
- `spaces agent spawn --command <cmd>` requires a command that launches claude, codex, or opencode, starts it in a fresh terminal of the current directory's workspace (or `--workspace`), and returns only once the agent is ready: identified by foreground detection and holding bracketed paste steadily for three seconds, which covers the gap before its composer accepts input. Hooks are not required, because a promptless Codex never signals and hooks may await trust review.
- A spawned command that ends before detection fails the spawn at once with its exit and last output lines. One that keeps running without becoming ready fails after the budget (default 90 seconds, `--timeout`), naming the command, pointing at `spaces terminal tail`, and leaving the session running.
- Spawn sends no prompt. Only the orchestrator driving the session can see and answer first-run dialogs, sign-in, or provider timing that swallow input. `spaces terminal send text <session> <text> --submit` delivers a prompt as a paste followed by a separate Enter, so every supported agent runs it, and reports success only once both reached the terminal.
- `spaces agent kill <session>` ends only coding agents: a signaled child is stopped after its subscribers are told it exited, an unsignaled session only when it was launched as an agent, and a shell or process terminal is refused.
- No command claims to interrupt an agent's turn. Steering is sending ESC yourself (`spaces terminal send bytes <session> 27`), whose meaning depends on the agent's current screen. Sending input records no status change; status changes only through the agent's own signals.
- `--device` on spawn, list, status, the brief commands, kill, subscribe, and unsubscribe acts on a paired device. Remote spawn requires `--workspace`.

### Briefs
- Two kinds of free text sit beside the work, and Spaces derives neither from prompts or output. Workspace notes are the user's: free text on a workspace, entered when creating it on the Mac or edited there later, trimmed, cleared by an empty edit, and deleted with the workspace. The Mac is the only client that shows them; over the CLI and MCP only `spaces_workspace_list` returns them. A brief is the coding agent's: one markdown status page per agent session, which the agent writes about its own work for the user and Spaces shows read-only beside its terminal on the Mac and iOS.
- Any terminal with a coding-agent row can keep a brief, whether foreground detection or a hook signal created the row; unlike a subscription, it needs no hook signal. Any other terminal is refused with `No agent session for terminal <id>. A brief needs a coding-agent session (detected or hook-signaled).` The brief lives on the agent's row and is deleted with it.
- `spaces agent brief write [markdown]` replaces the whole brief with the argument, or with stdin when it is omitted (markdown that starts with `-` goes after `--`). `spaces agent brief read` prints it verbatim, or prints `No brief for terminal <id>.` to stderr and exits 1. `spaces agent brief clear` removes it. All three default to the current terminal's session and accept `--session`. The MCP tools are `spaces_agent_brief_write` (an empty `markdown` clears the brief), `spaces_agent_brief_read` (which answers, rather than fails, when there is no brief), and `spaces_agent_brief_clear`. Only `brief read` and its tool return the full text; every other orchestration surface shows the summary.
- The write tool's description is what teaches an agent to keep a brief: write it for the user, lead with a one-line headline, keep a Status section (with an expected finish time for a step longer than a few minutes), a Questions for you checklist, and a Tasks checklist, stay under one screen, and update it when a step starts or finishes, a question comes up, or an estimate changes.
- A stored brief has CRLF line endings turned into LF, every control character except newline and tab removed, and surrounding whitespace trimmed, and is capped at 8000 characters. A write that leaves nothing clears the brief and reports `Cleared agent brief.` rather than `Wrote agent brief.`. A brief has no unread state, and writing or clearing it never changes the agent's status or re-dates its alert.
- The summary is the brief's first line that still has text once leading markdown markers are removed (heading `#`s, a list `-` or `*`, or a number and `.`, each only when a space or the line's end follows it, and a quote `>`, however they nest), with tabs turned into spaces, cut to 120 characters ending in `…`.
- On the Mac, a terminal pane whose session belongs to an agent with a brief shows the brief beside the terminal, for local and paired-device panes alike, read-only, with its links opening in their default app. Whether it shows belongs to the agent, not the pane, and lives in memory: every brief shows by default, a hide holds through rewrites, a clear, and the brief coming back, and a relaunch shows every brief again. `Cmd+Opt+B` toggles the focused pane's brief (in a panel window, the pane its identity strip names) and passes through to the terminal when that pane has no brief. When the brief goes away while it holds keyboard focus, focus returns to the terminal.
- On iOS, an agent's terminal screen opens its brief in a sheet on its own whenever the agent has a brief the user has not hidden: on entering the screen, or when a brief first arrives while it is open. Dismissing the sheet hides that agent's brief until the user asks for it again; the choice belongs to the agent, holds across rewrites and a clear, and lasts until the app relaunches. A rewrite re-renders an open sheet in place, and a clear closes it without counting as a hide. Web links in it do not open. The brief arrives with the device overview, which refreshes every 30 seconds while a terminal is open, so the sheet can trail the agent's latest write by that much.

### Subscriptions
- `spaces agent subscribe <session>` watches a child from the current terminal (or `--subscriber`). The child must have signaled at least once, except a terminal Spaces launched for an agent, whose row is never dropped without an exited notice. A terminal cannot watch itself, and a subscription that would form a cycle is rejected. The spawning terminal is subscribed to a spawned child once the child has an agent row.
- A cross-device watch (`--device`) is delivered by this machine's daemon watching the device; subscribing needs the device reachable and unsubscribing works offline. Cross-device cycles cannot be detected, so avoiding them is the operator's job.
- When a watched child goes blocked, done, or exited, the subscriber receives one block: `[spaces] <label> (<kind>) is <state>`, then two-space-indented `project`, `workspace` (full directory path), `branch` (when there is one), `session`, `brief` (the brief's summary, when there is one), and `link` lines. The kind (claude, codex, opencode) is remembered from identification, so an exit still names it; an agent never identified reads `coding agent`. The block states what happened without instructing, never starts with a character an agent treats as command syntax, and is submitted as a paste plus a separate Enter.
- The free-text fields (label, kind, project, workspace, branch, brief) have quotes, backslashes, shell metacharacters, and control characters stripped, because a plain-shell subscriber executes each submitted line; a summary `don't` arrives as `dont`.
- A block is injected only while the subscriber is idle (its agent idle or done, or a plain terminal). While it is busy, held events also ride on its next `spaces_*` MCP tool result as `pendingAgentEvents`; each event is delivered exactly once, by whichever path comes first. Repeated transitions of one child collapse to its latest state, and a held blocked notice is withdrawn if the child resumes first; done and exited are always delivered. A subscriber whose terminal has ended loses its held events and watches.
- A child's exit is announced exactly once to each subscriber, and recorded once in its history, however it is noticed and even when it happens during a kill or a workspace stop.

### Hook installation
- Spaces wires each supported agent's global hooks to `spaces agent signal`: Claude Code (`~/.claude/settings.json`), Codex (`~/.codex/hooks.json`, with the hooks feature enabled in `~/.codex/config.toml`), and opencode (a plugin under `~/.config/opencode/plugin/`). The hooks report session start, prompt submission, tool start and completion, permission prompts, and turn completion; Claude Code and Codex also report session end, and opencode the permission answer.
- Spaces never writes an agent's configuration unasked: hooks are installed from the launch setup step or Settings, nowhere else.
- Hooks call the CLI by the absolute path resolved on the agent's host at install time (installed Linux daemons use the stable `~/.spaces/bin/spaces`), never through the hook's PATH, since a hook that silently cannot find the CLI would look installed while never firing. Installing fails when the CLI cannot be found.
- Each agent reads as: not installed; out of date (written by an older hook version, missing a lifecycle event, pointing at a CLI path that is gone, or, for Codex, with the hooks feature off); switched off in the agent; awaiting the agent's trust review; or installed. The hook version changes whenever the hooks Spaces writes change.
- Codex runs no hook until the user approves it in Codex. Installing Codex hooks discards the approval the previous Spaces entries carried (approvals of the user's own hooks are untouched), so rewritten hooks are never reported installed while Codex declines to run them. Entries switched off in Codex are reported ahead of entries awaiting review. Both states offer Reinstall, and a row for This Mac updates by itself once the user finishes in Codex; a paired device's rows refresh when the section reopens.
- Installing replaces out-of-date Spaces hooks rather than adding beside them and adds exactly one entry per event. A hooks section with an unexpected shape, or a non-Spaces file at the opencode plugin path, is left untouched and reported as a failure. A config symlinked into a dotfiles repository is written through to its target. Codex's hooks feature is enabled through the Codex CLI, and success requires Codex to confirm it is on. Agents install independently.
- An agent is available only when its CLI resolves on the daemon host (daemon PATH, common user executable directories, or the login-shell PATH). Install actions appear only for available agents, and a failed install shows its reason until an install succeeds.

### Coding-agents setup step
- Launch offers a skippable coding-agents step after the Chrome Automation step when an agent detected on This Mac has hooks missing, out of date, switched off, or awaiting review. It can install for This Mac or any paired device.
- Skip and Continue both dismiss it. The dismissal is remembered against the hook version, so the step returns only when a release changes the hooks; installing another agent later does not bring it back. A launch with nothing to install records nothing.
- The decision reads This Mac only. If the local daemon cannot report agent status, the step is skipped for that launch without recording a dismissal. Launch never waits on it.

### Session restore
- A device records the coding agents whose work was cut short: by Stop All and Quit; by the device shutting its Spaces service down while agents run (restart, logout, shutdown); or by the service dying (crash, kill, power loss), which the device works out at its next start. Stopping one workspace or one agent records nothing, since that is a deliberate end. A cancelled Stop All and Quit keeps the agents it already stopped on the record and drops the still-running ones.
- Every live agent counts, however it started and whether idle or mid-turn. A terminal running only a shell is not recorded; workspace processes come back through their own start.
- An agent automation's agent comes back as a fresh run of that automation (one run per agent), counts as the automation's live work for its concurrency policy, and is not sent the automation's prompt again. An agent a script automation started comes back standalone. An agent whose automation was deleted, switched to a script, or already has work running cannot come back and is reported as such.
- A device holds one record at a time and reports it in its status. Restore brings back every agent on it and Skip drops it; either answer ends the record. A restore the device cannot begin (its automations are not ready to take their agents back) leaves the record outstanding. A newer capture replaces an unanswered record, and an answer naming a replaced record is refused.
- Restoring relaunches each agent in its workspace and directory with its original options, resuming its conversation when the agent reported one it can resume; a resumed agent is not sent its start prompt again, since the conversation already holds it. An agent comes back as a fresh conversation running its original command, prompt included, when it reported no conversation or never finished a turn in it. One-shot runs (`codex exec`, `codex review`, `claude -p`, `opencode run`) and `codex fork` come back as fresh runs; `opencode run -i` resumes. Claude Code subcommands (`claude attach`, `claude mcp`, `claude update`, and the rest) come back exactly as written. Environment assignments typed before the command are dropped.
- Restoring does not start workspaces. Agents that fail to relaunch, including one whose directory is gone, are named with the reason and the rest come back; the record is answered either way, so nothing relaunches twice. A restored agent is restorable again.
- The Mac offers the record as a launch setup step and as a sheet when any device starts reporting one while Spaces runs (a crashed local daemon, a paired device coming back). iOS offers it as a sheet for the connected device that closes only by answering; restoring from a phone brings the agents back on the device, among its terminals. The offer marks agents that can only come back as a fresh conversation and says that skipping is final.
- Answering clears the record on the device, for every client. An answer that does not reach the device changes nothing and keeps the question; one that arrived with its reply lost still brings the agents back, in fresh panes. A device is offered only while its daemon is compatible with the app; one that needs a daemon update keeps its record until updated.
- A restored agent returns to the pane its predecessor held (tab, split position, window); an agent typed into a terminal takes over that terminal's pane. Panes of agents on an outstanding record stay open as ended sessions until it is answered: Restore refills them and Skip closes them. Placement belongs to the answering Mac; another Mac sees the predecessors end and the restored agents appear as fresh sessions.

## CLI and MCP
- The CLI acts on this machine's daemon by default. `--device <name-or-id>` targets a paired device for `project list`, `workspace list|create|start|stop|restart`, `terminal list|send text|send bytes|tail`, and the agent commands; the MCP tools take an optional device the same way. Remote send and tail need no terminal attachment, so an orchestrating agent can drive sessions it never renders.
- With `--device`, workspace start, stop, and restart require `--workspace <id>`, since a remote device cannot infer a workspace from the caller's directory. `agent signal` has no `--device`: an agent may read a peer device's status but never forge it.
- `spaces workspace start|stop|restart` and `spaces terminal create` target `--workspace <id>` or else the deepest workspace containing the current directory, never the home project's workspace. They report the resolved workspace, and when nothing resolves they name the directory and say to run inside a workspace or pass `--workspace`.
- `spaces workspace stop` is the GUI's Stop (see [Panes and tabs across a stop or restart](#panes-and-tabs-across-a-stop-or-restart) for what a running Mac app then closes).
- `spaces terminal create` opens an ad hoc terminal at the workspace directory with the workspace's environment, like the app's `New terminal`. It is ended by `spaces terminal stop`, workspace Stop or Restart, and Stop All and Quit.
- `spaces terminal stop <session>` ends one session the way stopping its runtime target does (for an automation run's session, it cancels the run). An id naming nothing live is an error with a nonzero exit, not a reported stop.
- `spaces terminal show <session-id>` asks the Spaces app running for the caller's profile to open the session's pane; with no app running it fails with a nonzero exit instead of reporting success. The CLI has no command to focus a workspace target by name.
- `spaces terminal tail` replays the session's retained transcript at its last known terminal size, so wrapped lines and full-screen redraws match the live session, and a full-screen program that paints once and updates in place stays readable. An orchestrator is never handed blank output for a working session. `--lines <n>` returns the last n lines of history, not only the screen; a scrolling session keeps scrolled-off output up to the retained transcript bound, a full-screen program returns what it has, and output cleared with a full-screen erase stays in scrollback and in tail. For sessions identified as coding agents, tail omits a faint inline suggestion that starts at the cursor, including its wrapped continuation; all other output, faint text elsewhere included, stays.
- `spaces mcp` runs a stdio MCP server with project, workspace, terminal, paired-device, and agent tools. Agent lifecycle signals are CLI-only hooks, never MCP tools. The Claude Code MCP setup Spaces shows registers the server user-scoped, so it works in every directory.
- An MCP server survives a Spaces update. When the daemon speaks a newer protocol than the running server, the call in flight answers "Spaces was updated on this device, so this MCP server is reloading itself onto the updated build. Retry the call." and the server reloads onto the installed build without dropping the connection, so the agent's next call works. A daemon older than the server keeps the "update Spaces" error, since reloading cannot help it.
- `spaces://terminal/<session-id>` links, shown in agent list output and notification blocks, focus that session's pane: on the Mac in place (directly from an in-terminal click), on iOS in the terminal viewer. `?device=<id>` opens it in a remote-attached pane. A missing session, an unpaired device, or a session the named device does not have is reported. On the Mac, a `spaces://pair` link says to pair from the phone, and an unrecognized `spaces://` link is reported.

## iOS App

### Access and devices
- iOS requires an active subscription: one auto-renewing yearly plan with a free trial. Without one, only the paywall shows. The trial is offered only to a customer still eligible for it, and canceling the App Store sheet is not an error. The Mac app and website are unaffected.
- iOS works with one selected device at a time. Switching device returns every tab to its list, so no screen from one device stays open for another.
- Lists refresh every 2 seconds while shown, and every 30 seconds while a terminal or browser session is open on top of them. A failing refresh is reported only after about five seconds of continuous failure, so a blip on returning from the background passes unnoticed; a failed action the user asked for is reported immediately.
- Both apps default to a dark appearance with System, Light, or Dark, saved per device.
- Demo Mode tours bundled sample data instead of a paired device, so someone without a Mac can see the app. It hides the real paired devices without changing them (turning it off restores them exactly), blocks pairing, device switching and renaming, and terminal input, and hides any action it cannot serve. Workspace, process, and agent lifecycle actions work against the sample data; a row with no recording of its own replays a sample session of the same kind and name. One sample agent keeps a brief. Demo terminals are read-only, sized to the viewer, and have no scrollback. Demo Mode persists across launches.

### Spaces, Agents, and search
- The Spaces tab lists every workspace that is not hidden, including terminal sessions no configured row represents, with the home project first. The home project offers only Terminal and Hide.
- Starting a workspace launches only its configured processes, never a browser session, coding agent, or terminal.
- Tapping a row opens its terminal when it has a session, and otherwise runs the configured process. An exited configured process with a session still opens for inspection; Run is in its menu.
- Every Stop on iOS asks for confirmation; Restart does not. Hide acts at once (see [Hiding](#hiding)); Delete confirms first. A default workspace offers no Delete.
- Search on the Spaces tab matches loosely over workspace, project, directory, and each row's title and detail, and lasts for the app session. A workspace whose own name, project, or directory matches keeps all its rows. Results keep the list order.
- The Agents tab groups running agents as Blocked, Done, then Working (running agents with no activity signal count as Working). Agents that are not running are not listed; they stay reachable from their workspace.

### Terminal
- Opening a terminal shows a preparing state until the session has been resized to the phone, so the session's previous size never appears. Reopening a terminal shown before displays its last screen at once and then updates; one that ended or was taken over meanwhile is corrected as soon as the device reports it.
- Returning to an open terminal after a short trip out keeps the live connection and confirms the screen in one exchange. After a longer absence the last screen stays up while the terminal reconnects immediately, with no banner unless that fails. The Spaces list likewise keeps its rows and refreshes in place.
- Ended rows are read-only: no attach, takeover, input, resize, or reconnect; they show the final render when one exists. Leaving a terminal detaches the viewer, and work cancelled by leaving never surfaces as an error.
- Showing or hiding the software keyboard never resizes the session: rows shift to keep the cursor visible, so other viewers see no reflow.
- Mac file paths and HTTPS links to images, video, PDF, text, Markdown, and HTML preview inside Spaces (HTML scoped to the single file, with no sibling or network loads); previews over 4 MiB for text, Markdown, or HTML are refused. Other web links open in an in-app Safari view with the device's normal cookies, and `spaces://` links navigate in the app.
- Paste (key, `cmd` then `v`, or the system Paste) sends clipboard text as a paste; a clipboard image opens the composer with the image attached rather than sending it. `cmd` then `v` is consumed even when the clipboard is empty. A modifier key applies to the next text, arrow, Return, or Backspace, so `shift` then Return sends Shift+Enter without a hardware keyboard.
- The composer sends as one burst: the text, then each image as a path on the owning device, then Return, all with paste semantics. Images follow the Mac's image-paste rules. If any step fails, Return is not sent and the whole draft is kept; a successful send clears it. The draft survives closing and reopening the composer.

### Browser sessions
- Tapping a browser-session row opens the workspace's dev server in an in-app web view; the row has no run, stop, or restart, since a browser session is a URL.
- Each service keeps the same origin identity it has in the Mac's Chrome flow, so cookies and storage are isolated per service.
- It works for local and remote (Linux) workspaces alike, straight from the phone to the owning daemon, so a sleeping Mac does not matter. Services on IPv4 or IPv6 loopback both work. A service that is not running shows an error naming the service, workspace, and device.
- Backgrounding the app closes browser-session connections and foregrounding restores them; a dev server's live-reload clients reconnect on their own.
- Screenshot captures the visible page as PNG (10 MiB cap) and opens Markup. Closing Markup stages the result in a single slot, replacing any earlier screenshot, for attaching from a terminal's composer; a result over the cap is not staged.

## Updates and Daemon Compatibility

### Releases
- Every release is published as a pre-release first and reaches everyone only when promoted; promotion changes nothing about the build. A release superseded before promotion is never promoted.
- "Receive pre-release updates" (off by default) switches the Mac between promoted releases and every published release, from the next update check and without reinstalling. A Mac on pre-releases moves to the superseding release at its next check, so a bad pre-release corrects itself.
- Upgrading Spaces on Ubuntu with a running daemon keeps the daemon's process and sessions through an in-place handoff, even while a long transcript replay keeps it briefly unavailable. When the handoff cannot be accepted or does not reach the installed build, the installer reports an error and leaves the running daemon alone.
- Launched from `/Applications`, the app keeps its helper links and LaunchAgent aligned with the installed bundle without restarting the daemon.

### Daemon compatibility and restart
- An app and a device's daemon update on their own schedules. While they are compatible, updating the app never restarts the daemon or interrupts its terminals, processes, and agents.
- A running daemon alone upgrades its profile's database schema. A staged CLI that needs a newer schema refuses to migrate under it and points to `spaces daemon apply-update`, which loads the staged daemon in place with sessions kept.
- When a device has a newer Spaces installed than its daemon runs, the Mac app applies it in place without asking, even to a daemon too old to otherwise talk to, since the restart request crosses the version gap. Sessions keep running; the only sign is an "update pending" hint and the usual reconnect. Whether an update is waiting is reported by the device, never inferred from a client's own version.
- If the device still runs its old build about 30 seconds after the request, Spaces says so once, naming both builds, stating that nothing was interrupted, and giving the one manual step for that kind of device (Linux: a command to run there; a remote Mac: open Spaces on it; this Mac: Restart Local Daemon), with Try Again. It never calls this a failure, because a slow restart and a refusal look the same, and says nothing while the device is silent.
- A daemon too old for the app blocks only that device, with an explanation; an app too old for the daemon asks the user to update the app. A usable device is never blocked over a pending update.
- A blocked device stays blocked rather than alternating with offline. Spaces drops its live connection to the device but keeps checking it, so the block clears by itself once the versions match; a blocked device that becomes unreachable reads offline.
- A too-old daemon with nothing newer installed gets no update action, only where to install one: open Spaces on that remote Mac, Check for Updates for this Mac, or the version-pinned install command for Linux, which updates in place and keeps sessions. A Linux device paired over SSH also offers Update over SSH, which runs that installer on the device, keeps sessions, shows the installer's output on failure, and keeps the command visible throughout.
- When a device's daemon moves forward, older apps are blocked on it until they update; their sessions keep running underneath.
- Messages name the daemon's running build, the device's installed build, and the app's version, but what Spaces offers comes only from the device's own report, never from comparing an app's version with a daemon's.
- A daemon that has begun shutting down (a stop, a restart, or an update handoff) refuses every request with a clear "shutting down" answer, liveness pings included. A client that finds no live daemon waits briefly during an update handoff, since a replacement is on its way, but starts a fresh daemon at once after a plain stop or restart.
- The iPhone applies a staged update by itself only to a device it is blocked on, silently, and reports once if the device is still on its old build about 30 seconds later, with Try Again. On a device it can still use, a staged update is a quiet card with an apply action, never applied behind the user's back. A blocked device's screen shows the version gap and at most one action, and none where the phone cannot fix it: a Linux daemon with nothing newer installed is updated from a Mac, and an app behind its device is updated from the App Store.
