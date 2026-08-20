---
name: manual-review
description: Stage each PR worked on in this session for the user's hands-on review — one PR at a time, bringing up the Mac app, a paired iOS simulator, and/or a paired Linux daemon as the change requires, with the profile seeded so the changed behavior is immediately exercisable. Use when asked to set up manual testing, hand-test PRs, or bring up the app for a PR.
---

# Stage session PRs for manual review

Turn each PR from this session into a running environment the user can test by hand. The user drives the pace: set one PR up, hand it off with what to exercise, and wait for their verdict before touching the next.

## Enumerate and order

List the PRs worked on in this session (session context, memory notes, `gh pr list` for the session's branches). Present the list with the surfaces each needs, then stage them one at a time in the order the user picks (default: the order they were shipped). Each PR is tested from its own worktree — never from a checkout of another branch that happens to contain similar code.

## Decide the surfaces from the diff

Read the PR's changed paths and bring up only what the change can reach:

- Mac-client-only changes (`SpacesApp`, `spacesui`, AppKit surfaces) → **Mac app** alone.
- Anything the iOS client can reach → **Mac app + paired iOS simulator**. That is not just `apps/ios`: daemon and Device API changes (`spacesd`, `spacesterminalcore`, `spacesdevicecore`, `spacesclientcore` protocol changes) are mobile-reachable because iOS consumes the same daemon behavior.
- Changes to the Linux daemon path (`spacesd` code behind `#if os(Linux)`, remote transport, provisioning scripts) → **Mac app + paired iOS simulator + paired Linux daemon**, so the user sees the remote device end to end.

When a fix has a sibling on the other client (shared data flow), stage both surfaces even if only one side changed, so the user can confirm parity.

## Ground rules for every stage

- Only ever close Spaces **client apps** to obtain desktop control — the installed client (`/Applications/Spaces.app`) and the previous PR's dev client. Never kill any `spacesd` daemon or its child processes (caddy, sessions), and never touch other worktrees' running instances.
- Run each worktree's **own** binaries and scripts by absolute path (`<worktree>/scripts/dev-build-and-launch.sh`, `<worktree>/apps/macos/.build/debug/{spaces,spacese2e}`). Binaries resolve their worktree-scoped profile from where they sit; the session's cwd is not a reliable indicator of which worktree you are acting on — check before every launch or build.
- Never export `SPACES_DB_PATH` to reach a dev profile; it names ephemeral throwaway profiles only.

## Mac app

Launch with `<worktree>/scripts/dev-build-and-launch.sh --local` (builds if needed; prints the profile root). Confirm the app process stays up and note its pid so the teardown for the next PR closes exactly this client.

## Seed the profile

A fresh dev profile is empty; seed exactly the state the PR's behavior needs, using that worktree's `spacese2e`:

- Projects/workspaces: create small git repos under `<profile-root>/fixtures/<name>` and register each with `spacese2e seed-fixture --project-dir <dir> --template harbor|lantern|atlas --docs-url http://localhost:4173/docs --admin-url http://localhost:4173/admin` (`--docs-url` and `--admin-url` are required; any well-formed URLs work for manual review). Distinct names make search and lists meaningful. `spaces workspace create --project <id> --branch <name>` adds branch workspaces.
- Feature-specific rows: `spacese2e automation-create` for automations, `spacese2e hide-workspace` for hidden-state cases, and the other `spacese2e` seeding commands (`--help` lists them).
- Seed the states the PR distinguishes, not just one happy path — e.g. for a visibility change, at least one hidden and one visible workspace; for a scheduling change, both a manual and a cron automation.

## Paired iOS simulator

1. Pick an available shut-down iPhone simulator (`xcrun simctl list devices available -j`), boot it, and `open -a Simulator`. Reuse an already-booted simulator only if this review staged it; a booted device may belong to mobile E2E or another worktree, and installing over it replaces that run's app and state.
2. Build from the PR's worktree with absolute paths: `xcodebuild -project <worktree>/apps/ios/SpacesMobile.xcodeproj -scheme SpacesMobile -configuration Debug -destination "platform=iOS Simulator,id=<udid>" -derivedDataPath <worktree>/apps/macos/.build/ios-derived-data build`.
3. `xcrun simctl install <udid> <derived-data>/Build/Products/Debug-iphonesimulator/SpacesMobile.app`, then launch with the DEBUG paywall bypass: `SIMCTL_CHILD_SPACES_MOBILE_PAYWALL_BYPASS=1 xcrun simctl launch <udid> dev.usespaces.spacesmobile`.
4. Pair against the worktree's daemon: `<worktree>/apps/macos/.build/debug/spacese2e open-device-pairing-window` prints a JSON object; extract its `pairingLink` (the `spaces://pair?...` URL) and deliver that with `xcrun simctl openurl <udid> "<link>"`. The app raises its pairing confirmation sheet; give the user the JSON's `pairingCode` so they can compare. Windows are one-time and expire — open a fresh one per attempt.
5. Each PR's profile is a new pairing; repeat this per PR, and `simctl terminate` + reinstall when switching to the next PR's build.

Leftover simulator builds leave stale Swift modules in that worktree's `ios-derived-data`; if a later `verify.sh` or test lane in the same worktree fails with missing-type compile errors after the branch moved (rebase, merge), delete `<worktree>/apps/macos/.build/ios-derived-data` and rerun.

## Paired Linux daemon

Host configuration (SSH host/user/port, daemon host/port, roots, auth token) lives in the gitignored `.env` at the repo root, loaded via `scripts/spaces-e2e-env.sh` — source it first rather than assuming the remote is unconfigured. Deploy the worktree's `spacesd` to the remote with `<worktree>/scripts/dev-build-and-launch.sh` run **without** `--local`: that flow builds the Linux artifact, installs it into the worktree's own remote profile, and starts the daemon (the lower-level `apps/macos/scripts/deploy_linux_spacesd_e2e.sh` only builds and uploads an artifact for one `--profile`; it is not the full install path).

Pair clients against the **remote** daemon, not the local Mac one: `<worktree>/apps/macos/.build/debug/spacese2e open-remote-device-pairing-window` opens a pairing window on the Linux profile and prints JSON with `pairingLink` and `pairingCode`. Redeem one window from the Mac with `spaces device pair --link <link>`, and open a second window whose link goes to the simulator via `simctl openurl`, so the iOS app actually talks to the Linux daemon under review. Respect the shared-host rules: per-profile daemon lanes, and never prune the remote's roots by mtime.

## Hand off, then wait

Tell the user, in one message: what is running (surfaces, pids, worktree/profile), what was seeded and why, the pairing code if a pairing sheet is waiting, and the 3-5 behaviors this PR changed that are worth exercising (from the PR description and `docs/spec.md` diff — user-visible behavior, not implementation). Then stop and wait for their verdict. Do not tear down, rebuild, or move to the next PR until they say so.

## Between PRs

Quit the current PR's dev client (its pid, nothing else), `xcrun simctl terminate <udid> dev.usespaces.spacesmobile` if an iOS build was staged (terminate requires the device UDID), and leave every daemon running. Then stage the next PR from its own worktree.
