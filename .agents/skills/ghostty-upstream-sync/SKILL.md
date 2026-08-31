---
name: ghostty-upstream-sync
description: Sync the Ghostty fork with upstream — fast-forward the fork's main from ghostty-org/ghostty, merge main into the fork's spaces branch, run the Ghostty test lanes, then bump the submodule sha in this repo and open a PR. Use when asked to update, sync, or merge upstream Ghostty.
---

# Sync Ghostty fork with upstream

The fork lives at `apps/macos/vendor/ghostty` (origin = `yogesh-dhande/ghostty`, upstream = `ghostty-org/ghostty`). The fork's `spaces` branch carries all Spaces-specific commits on top of upstream `main`. Read the "Ghostty Dependency Workflow" section of `AGENTS.md` before acting. Never open issues or PRs in the ghostty repos — the only PR belongs in this Spaces repo.

## 1. Fast-forward fork main

1. In the submodule, `git fetch origin` and `git fetch upstream`.
2. Confirm `git rev-list --count upstream/main..origin/main` is `0` (fork main has no unique commits). If it is not, stop and ask the user how to proceed.
3. Push without touching the working tree: `git push origin upstream/main:main`.

## 2. Merge main into spaces

1. Check out `spaces` at `origin/spaces` with a clean submodule worktree.
2. `git merge origin/main`. For conflicts, per file decide whether the fork side is a Spaces feature to preserve or an old patch upstream has since absorbed:
   - Preserve fork features: host-managed termio backend, `ghostty_session_*` embedded APIs, screen-change/render-scroll tracking, `macos-use-login-shell` (fork-only option — upstream has no trace of it, do not conclude it was removed), `drainMailboxTo`.
   - Drop fork patches that upstream now carries. Verify with `git log upstream/main -- <path>` or the GitHub compare API before dropping; when a fork dependency pin (e.g. libxev) differs, confirm the fork's pinned commit is an ancestor of upstream's new pin.
   - When upstream moves an API (signature, module, ownership), port the fork-side code to the new API rather than keeping the old call shape.
3. If Zig APIs changed, port fork code accordingly; let compile errors drive the port. Notably, since Zig 0.16 the stdlib uses the `std.Io` concurrency model: `std.Thread.Mutex/Condition/sleep` no longer exist — use `std.Io.Mutex` (`.init`, `lockUncancelable(io)`, `unlock(io)`), `std.Io.Condition` (`waitUncancelable(io, &mutex)`, `signal(io)`, `broadcast(io)`), `std.Io.sleep(io, .fromMilliseconds(n), .awake)`, and pass `global.io()` to mailbox/queue ops (`std.testing.io` in tests).

## 3. Test the fork

Use the Zig toolchain pinned in `apps/macos/scripts/setup_ghostty.sh` (`ZIG_VERSION`). If upstream now requires a newer Zig, bump `ZIG_VERSION` in both `setup_ghostty.sh` and `build_linux_spacesd_artifact.sh`, the fixture archives and manifest versions in `apps/macos/Tests/setup_ghostty_*.sh`, and the Zig version in `docs/dev.md` — all in the same Spaces PR.

In the submodule, all three must exit 0:

1. `zig build`
2. `zig build test -Demit-xcframework=false -Demit-macos-app=false`
3. `zig build test-lib-vt`

Step 2 runs the Zig suites only. Plain `zig build test` also runs Ghostty.app's Xcode suite (`macos/GhosttyTests`), which tests the Swift app Spaces never links, and that test host needs macOS 26 to load (it references `SwiftUI.Glass`, upstream fd17869d1). Spaces consumes only `GhosttyKit.xcframework` and `libghostty-vt`, which steps 1 and 3, the Zig suites, and the Spaces gate cover, so the Xcode suite is not part of the fork gate.

Then push: `git push origin spaces`.

## 4. Bump the submodule sha in this repo

1. From `main`, create a branch (e.g. `ghostty-upstream-sync-<yyyymmdd>`), stage the new gitlink for `apps/macos/vendor/ghostty`, plus any Zig-pin edits from step 3.
2. Rebuild local artifacts: `apps/macos/scripts/setup_ghostty.sh --build`. If packaging fails because `macos/GhosttyKit.xcframework` already exists in the submodule, that is a stale gitignored leftover — delete it and rerun.
3. Run `scripts/verify.sh` and let it pass.
4. Commit, push, and open a PR describing the upstream range merged and any port work. Then follow the repository's standard post-commit review loop from `AGENTS.md`.
5. Watch the PR checks. `publish-ghostty-artifacts` must publish (or find complete) the `ghostty-artifacts-<full-sha>` release for the new pin. If `verify` fails a timing-sensitive test that passes locally, check another recent PR's verify log for the identical failure before suspecting the merge — known runner flakes are tracked in issues; rerun with `gh run rerun <id> --failed`.

## Known constraints

- Ghostty's vendored `translate_c` runs a bare `zig env` at configure time; both build scripts prepend the pinned toolchain to `PATH` for this. Do not remove those exports.
- The submodule gitlink is the single source of truth for the Ghostty commit; CI builds from it, never from local uncommitted state.
