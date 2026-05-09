# Built-In Terminal Plan

This document tracks the tmux-free terminal migration for Spaces. It is a working implementation plan and should be revised as the code changes shape.

## Goals
- Replace iTerm2, Ghostty, and tmux with a Spaces-owned terminal runtime.
- Keep libghostty patches additive and narrowly scoped.
- Treat one terminal session as one window in v1.
- Make terminal sessions durable independently of any one local window or remote viewer.
- Provide per-session control through `spaces terminal ...`.

## Non-Goals For V1
- No tabs.
- No panes or split-tree layout.
- No tmux compatibility layer in the new path.
- No attempt to preserve current host-specific terminal identities.

## Target Modules
- `spacesterminalcore`
  tmux-free runtime model, PTY ownership, client ownership, output indexing, snapshots, and session addressing.
- `spacesterminalghostty`
  libghostty bridge, additive patch wrappers, theme/keybinding loading, and render-state extraction.
- `spacesterminalui`
  AppKit terminal windows and local session attachment.
- `spacesterminalcontrol`
  local and remote control protocol, socket server, auth, and CLI integration.

## Runtime Model

### TerminalSession
- Stable Spaces-owned terminal identity.
- One PTY-backed child process or login shell.
- One active input owner at a time.
- Zero or more passive viewers.
- Output log and snapshot state owned by Spaces, not by a window.

### TerminalClient
- Stable client identity for one attached consumer.
- Client kinds for v1:
  - local Spaces window
  - CLI observer
  - remote viewer
- Every client records label and connection context.

### TerminalAttachment
- Binds one client to one session.
- Tracks mode: `owner` or `viewer`.
- Owner controls PTY input and PTY size.
- Viewer receives snapshots and live output only.

## Additive libghostty Patch Surface
- Raw PTY output callback registration per session or surface.
- Raw PTY input injection that bypasses paste semantics.

Possible later additions only if v1 proves they are needed:
- Explicit headless surface lifecycle hooks.
- Incremental snapshot version markers.
- More structured lifecycle event callbacks.

## Migration Strategy

### Phase 1: Foundation
- Add `spacesterminalcore`.
- Define session, client, attachment, and output-log model types.
- Keep the module tmux-free from the first commit.

### Phase 2: Ghostty Embedding
- Add `spacesterminalghostty`.
- Embed libghostty with additive patches only.
- Prove one Spaces-owned AppKit terminal window can render a PTY-backed shell.
- The current implementation includes a branch-local `GhosttyKit.xcframework` resolver, bundled Ghostty resource discovery, and a working `ghostty-embedded` session backend that owns the PTY, `send`, and output capture for `tail`.

### Phase 3: Session Control
- Add `spacesterminalcontrol`.
- Introduce per-session addressing.
- Add local commands for:
  - `spaces terminal list`
  - `spaces terminal send`
  - `spaces terminal key`
  - `spaces terminal tail`
  - `spaces terminal command`
  - `spaces terminal takeover`
- The current implementation uses per-session files plus a local Unix control socket and output log as the first local control transport.

### Phase 4: Window Ownership
- Add `spacesterminalui`.
- Make each local window an attached client rather than the session owner.
- Support close and reopen without killing the PTY.
- The current implementation starts this phase with a native Spaces-owned per-session window shell that follows an existing session, registers a local owner client attachment, and keeps text send, named-key send, and output tailing on the session control socket and output log instead of on the window itself.

### Phase 5: Workspace Integration
- Replace ad-hoc workspace terminal launch.
- Replace process launch and recovery paths.
- Replace coding-agent terminal tracking with session IDs.

### Phase 6: Deletion
- Remove tmux launch, recovery, and setup requirements.
- Remove iTerm2 and Ghostty adapters.
- Remove terminal-host configuration from the app and CLI.

## First Execution Slice
- Add `spacesterminalcore`.
- Capture the stable runtime entities there.
- Keep the types independent from AppKit and tmux.
- Use this module as the home for the first `spaces terminal` surface once the control layer is added.
- Current code in this slice defines `TerminalSession`, `TerminalClient`, `TerminalAttachment`, and `TerminalOutputChunk`.
- Current code in this slice also ships a working CLI-first daemon path for `spaces terminal command`, `list`, `send`, `key`, and `tail`.
- The current control protocol supports both text send and named-key send.
- `send` now goes through a per-session local request/response socket instead of a writable FIFO in the session directory.
- `show` now asks the running Spaces app to open a native per-session window shell for a given session ID.
- `show` now registers the native session window as a local owner client and detaches it on close.
- `list` now surfaces the active owner client ID plus attached-client counts for each session.
- The current native session window also surfaces its renderer mode so `script-pty` sessions remain explicit shell fallback windows while `ghostty-embedded` sessions use the libghostty-backed window path.
- Session metadata and runtime state now record an explicit backend kind, and the native window body is selected from that backend rather than inferred from whichever renderer happens to be available locally.
- The `script-pty` path now lives behind an explicit backend-runtime interface, so the current daemon is one backend implementation instead of the terminal architecture itself.
- Backend selection now lives in a dedicated `spacesterminalruntime` target so the Ghostty-backed runtime can be integrated without forcing `spacesterminalcore` to depend on libghostty-specific code.
- The built `spaces` binary has been verified against a fresh session for `command`, `list`, `send`, and `tail`.
- The `ghostty-embedded` backend has been verified against a fresh isolated session for `command`, `list`, `send`, and `tail`, with libghostty owning the PTY and feeding `output.log` through the additive raw-output callback.
- The native `ghostty-embedded` path is now app-hosted so the visible libghostty surface is the same session backend that serves `spaces terminal send`, `spaces terminal key`, and `spaces terminal tail`.
- `script-pty` remains the fallback window path while the session model is still growing toward multi-client owner or viewer handoff.

## Open Decisions
- Persistent store shape for terminal output chunks and snapshots.
- Local control transport format and auth model.
- App relaunch behavior for restoring local window attachments.
- Whether CLI observers attach as first-class clients or use read-only snapshots.

## Current Status
- [x] Create working migration plan in the repo.
- [x] Add `spacesterminalcore` as the first tmux-free module.
- [x] Add terminal session model types.
- [x] Add the first local control surface for `spaces terminal command|list|send|tail`.
- [x] Add the first `spacesterminalghostty` target and embedded Ghostty path-resolution seam.
- [x] Add the first libghostty-backed session backend.
- [x] Add the first libghostty-backed renderer bridge.
- [x] Add AppKit terminal window target.
- [x] Cut the first ad-hoc terminal path over from tmux for CLI-owned sessions.
- [ ] Delete tmux dependencies.

## TODO
- Clean up the branch-local Ghostty archive packaging so `libghostty-internal.a(ext.o)` no longer emits the current non-fatal ImGui symbol warnings during link.
