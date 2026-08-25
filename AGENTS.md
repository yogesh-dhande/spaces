# AGENTS.md

## Docs
- Put product behavior from the user's point of view in `docs/spec.md`.
    - Update `docs/spec.md` when UX or user-visible behavior changes.
- Put implementation details and the rationale behind design choices in `docs/implementation.md`.
    - Update `docs/implementation.md` when data flow, persistence, implementation structure, or the rationale behind a design choice changes.
- Put general design system guidelines in `docs/design.md`.
    - Update `docs/design.md` when the visual system, reusable interaction patterns, or UI styling guidance changes.
- Put product overview and adoption pitch in `README.md`.
    - Update `README.md` when the product overview, feature list, or adoption pitch changes.
- Put repository development, build, and deploy workflows in `docs/dev.md`.
    - Update `docs/dev.md` when development, build, deploy, or manual E2E workflows change.
- Keep docs concise and non-overlapping.
- Treat `README.md`, `docs/dev.md`, `docs/spec.md`, `docs/implementation.md`, and `docs/design.md` as current-state references, not changelogs; avoid temporal wording like "now", "no longer", "previously", "new", or "changed" when describing the intended steady state.
- User-facing docs are in `apps/web` which is published as a static website
    - Update `apps/web/app/docs/content.ts` when docs navigation or summaries need to reflect new product docs.



## Coding Guidelines
- When planning a new feature (whether or not in plan mode), ask me lots of questions until we align on intent, design, UX, and implementation. Ask me questions to help me figure out my unknowns and better think through the feature, its intent, scope, and desired outcome. Don't present a plan until I explicitly ask you to.
- For all coding tasks use your judgement to decide an appropriate lower power model and run that in a subagent.
- When user instruction contradicts previous instructions or documentation, explicitly ask for clarification before proceeding.
- Before making a non-trivial UI change (for new or existing features), present options as HTML mockups including the current design/state and 3-4 updated designs. Wait for a pick before implementing.
- When fixing a bug or performance issue for the mac app, consider whether a similar or related fix is needed for iOS and vice versa; the clients share data flow and UI patterns, so an issue in one often has a sibling in the other.
- Do not add fallback paths without explicit approval. We should first fully understand, implement, and harden the intended path without complicating code or behavior behind fallback paths.
- Do not add unnecessary options, arguments, alternate code paths, or script modes. Extra surface area should only be added when it supports real product behavior or behavior required for testing, and the intended path should stay clear and singular.
- When making breaking changes, explicitly ask whether backwards compatibility is needed. Do not make the decision on supporting or not supporting backwards compatibility without explicit approval.
- A performance change must be measured: capture the metric on the unmodified baseline, capture it again after the change with the identical procedure, and put the before/after numbers in the PR body.
- Tests should validate product behavior, not database schema shape. Do not add schema-only tests for table or column ownership. Code and behavior tests should cover the contract.
- Before committing, go through uncommitted changes to identify and act on:
    - wrong paths we went down and any code leftover from those that should be removed
    - excessive, unnecessary, and risky fallbacks in code that should be removed or simplified
    - any key non-obvious decisions made about how the product should work that should be captured in spec.md
    - unused or dead code that needs to be removed
    - places where the decision or logic is not obvious from the code (e.g. why a fallback path exists, and why it is written the way it is, etc). add docstrings and comments to code to make these clear
    - is there any refactoring recommended for the newly added or adjacent code?
    - do the tests accurately and sufficiently capture intended product behavior or are we testing for implementation details? do we need to add any more tests?
    - unnecessary fixes, fallback paths, options, arguments, or script modes we added during debuging that should be removed to avoid unnecessary code complexity, code maintenance, or performance issues.
- If on the `main` branch, switch to a new branch before committing changes. When asked to push, commit, push, and create a PR if there isn't one already. Do not add a coding agent name as a prefix to the branch name or the PR title as multiple coding agents may have contributed to the same commit. Please check the PR status before pushing to existing branches with previously opened PRs. If the PR is closed, create a new branch and a new PR.
- The established gate before committing is `scripts/verify.sh` (build, lint, and tests). Either run `scripts/verify.sh` yourself and let it pass, or let the pre-commit hook run it. Do not `git commit --no-verify` unless `scripts/verify.sh` has already passed for the same change; `--no-verify` only skips the redundant re-run, it does not skip the gate. You can skip the date if making only documentation or website changes.

- When running `git commit`, allow at least a 15-minute timeout so pre-commit checks can finish.
- Before each commit, use codex cli with gpt-5.6-sol model (high effort) to run a review of the uncommitted changes.
- Before finalizing a PR, run the affected e2e tests, commit, then use codex cli with gpt-5.6-sol model (high effort) to run a review against the target branch (e.g. main if branched off from main). This against-target review is needed only when finalizing a PR, not after every commit.
- When presented with review findings, create a table with estimates for probability of each bug occurring (1:10, 1:1000 etc), impact (scale of 1 to 10, 10 be worst), effort to write a failing test (high, medium, low) with reason (architecture vs narrow/rare edge case hard to codify), and recommendation for whether it is worth addressing the review based on the probability, impact, and complexity of the fix. 
    - Automatically fix any issues that are expected at reasonably frequency and have medium/high impact or anything that is a trivial correctness fix. 
    - Any issues that do not need to be fixed as they are irrelevant for the product UX (if unclear, ask me questions and wait for my input) can be documented as accepted behavior/risk to avoid surfacing the issue again. Once fixed and committed, rerun the review cycle and loop until no high impact issues remain.
        - Rare edge cases under normal usage patterns can be ignored. 
        - Issues that self heal quickly during normal usage can be ignored. 
    - Issues that are of reasonable frequency but low impact and require disproportionately high code complexity for the necessary fix can be deferred by creating a github issue for it. Make sure there isn’t an existing issue for it. 
    - Issues that are not relevant to how the product actually works (e.g. code paths in the ghostty fork that are unreachable given how Spaces uses it) are resolved with a code comment at the decision site explaining why the finding does not apply. Do not create a github issue for them.
    - Issues with a won’t-fix disposition are documented as accepted behavior/risk (code comment or spec note as appropriate), never written up as a github issue. Github issues are only for work we intend to do.

- When fixing a bug, reproduce it first by writing a failing test and/or using the real system, `~/projects/spaces/apps/macos/.build/debug/spaces` cli, and/or database inspection when practical.
- Use the e2e test scripts for hotkey-sensitive verification before resorting to ad hoc manual app launches. Those scripts may wait for desktop control instead of killing unrelated running Spaces instances.
- When manually launching a repo-local debug build, run that worktree's own binaries (`apps/macos/.build/debug/{SpacesApp,spaces,spacese2e}`) or `scripts/dev-build-and-launch.sh`. Each binary resolves its own worktree-scoped profile from where it sits, so the app, CLI, and E2E helpers stay on one profile with no shell binding.
- `SPACES_DB_PATH` names an ephemeral throwaway profile and nothing else. Profile resolution refuses a path inside `~/.spaces` or `~/.spaces-dev/profiles`, so never export it to reach a real profile — an inherited binding is what lets one profile's daemon serve another's state. Use `apps/macos/.build/debug/spacese2e profile-show` to look up a resolved profile's paths.
- Treat other worktrees' running Spaces instances as separate profiles. Do not kill them just to unblock your own workflow; only stop the app instance for the current profile, and let desktop-global verification wait for desktop control when another profile owns it.
- Remote/Linux daemon E2E and validation (e.g. `scripts/deploy_linux_spacesd_e2e.sh`, the remote-daemon e2e) read their host configuration — `SPACES_E2E_REMOTE_SSH_HOST`/`_USER`/`_PORT`, remote daemon host/port, workspace/git roots, host id, auth token — from the gitignored `.env` at the repo root, loaded via `scripts/spaces-e2e-env.sh`. The variables are not exported into a fresh shell, so source that env (or run the script, which sources it) before assuming the remote is unconfigured.

## Ghostty Dependency Workflow
- The Ghostty fork is tracked as a git submodule at `apps/macos/vendor/ghostty` on the fork's `spaces` branch.
- The submodule gitlink is the single source of truth for the Ghostty commit used by `GhosttyKit.xcframework` and `libghostty-vt`.
- Edit Ghostty in `apps/macos/vendor/ghostty`, commit and push fork changes to the fork's `spaces` branch, then update the parent repo's submodule pointer in the normal Spaces pull request that depends on that Ghostty change.
- Ordinary fork-updating changes land on the current `spaces` base; they do not carry an upstream sync. Upstream syncs are their own dedicated changes, run periodically: merge `ghostty-org/ghostty` `main` (mirrored onto the fork's `main` daily by the fork's `sync-main-from-upstream` workflow) into the `spaces` branch, resolve conflicts in favor of fork behavior (including the iOS GhosttyKit build, which upstream does not carry), then rebuild artifacts and run the fork and Spaces tests before advancing the gitlink.
- PR checks and Spaces app releases consume Spaces-owned prebuilt artifacts from a GitHub release named `ghostty-artifacts-<full-ghostty-sha>` in this repo. Trusted same-repo PR, main-push, manual, and release workflows build from the pinned submodule and publish reusable artifacts when the matching release is missing or incomplete.
- Fork PR checks build missing Ghostty artifacts locally without publishing reusable releases.
- Local debugging may use `apps/macos/scripts/setup_ghostty.sh --build --allow-dirty` for uncommitted Ghostty experiments, but Spaces PR and release workflows must use committed Ghostty fork work.

## Version Metadata Rules
- `apps/macos/AppVersion.plist` is the only place a Spaces version is authored. Never hand-edit `apps/macos/Sources/workspacecore/AppVersion.swift`, `apps/macos/Sources/SpacesApp/Info.plist`, or the version keys in `apps/ios/Info.plist`; change the source and run `scripts/sync-app-version.sh`. Spaces ships one version across every client, so all of them are generated from that source.
- A client must never decide anything about a daemon by comparing the daemon's version against its own build version. The clients and a given device's daemon are on unrelated release trains, so that comparison is meaningless: an iPhone build number says nothing about what is installed on a Mac or a Linux box. Facts about a device — what it runs, what it has installed, whether an update is staged — are reported by that device's daemon in `TerminalServiceDaemonStatus` and read identically by every client.
- The macOS `Info.plist` is regenerated wholesale from a template inside `scripts/sync-app-version.sh`. Add any new key to that template, not to the generated file, or the next sync silently drops it.

## Data and Migration Rules
- Installed/default database path: `~/.spaces/spaces.db`.
- Repo-local development builds default to `~/.spaces-dev/profiles/spaces/<branch-slug>-<worktree-hash>/spaces.db`.
- Migrations must faithfully carry existing user data forward to the new schema version; never lose or corrupt data the product still uses.
- Schema upgrades run serially through every intermediate version: each migration step moves exactly one version forward (vN to vN+1), and a database several versions behind applies each step in order. Never add a step that skips versions or a special-cased jump path.
- Tables and columns that no code reads or writes anymore may be dropped in a migration; remove their schema definitions in the same change.
- A workspace record is removed only by an explicit user action (deleting it, or deleting its project) or by the discovery scan retiring a workspace whose worktree is gone; deleting a workspace removes its settings and port assignments with it and keeps no tombstone. Never add any other path — migration, reset, repair, or cleanup — that can remove a project, or a workspace whose worktree is still valid.

## Web Rules
- Use the shared color and typography tokens in `apps/web/app/globals.css` instead of hard-coded values.


## Project Structure Rules
- Keep types split into focused files instead of combining many unrelated types in one file.
- Prefer unit tests for core logic; use UI tests only when unit tests are not possible.
- Add comments only where they reduce real ambiguity.
