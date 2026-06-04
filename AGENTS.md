# AGENTS.md

## Purpose
- Use this file for coding workflow, verification, and implementation guardrails.
- Put product behavior from the user's point of view in `docs/spec.md`.
- Put implementation details and the rationale behind design choices in `docs/implementation.md`.
- Put UI design and interaction guidelines in `docs/design.md`.
- Put product overview and adoption pitch in `README.md`.
- Put repository development, build, and deploy workflows in `docs/dev.md`.

## Product Constraints
- `Spaces` is a macOS Swift app for orchestration of coding tools
- The CLI is named `spaces`.

## Coding Agent Workflow
- Do not add fallback paths without explicit approval. We should first fully understand, implement, and harden the intended path without complicating code or behavior behind fallback paths.
- Before committing, go through uncommitted changes to figure out if there are any unnecessary fixes, dead code, or fallback paths we added during debuging that we should consider removing to avoid unnecessary code complexity, code maintenance, or performance issues.
- If on the `main` branch, switch to a new branch before committing changes. When asked to push, commit, push, and create a PR if there isn't one already. Do not add a coding agent name as a prefix to the branch name or the PR title as multiple coding agents may have contributed to the same commit. Please check the PR status before pushing to existing branches with previously opened PRs. If the PR is closed, create a new branch and a new PR.
- When fixing a bug, reproduce it first using the real system, `~/projects/spaces/apps/macos/.build/debug/spaces` cli, and/or database inspection when practical, then add a test, implement the fix, and confirm both the test and the real workflow.
- Use the real-system scripts for hotkey-sensitive verification before resorting to ad hoc manual app launches. Those scripts may wait for desktop control instead of killing unrelated running Spaces instances.
- When manually launching a repo-local debug build, use the derived profile helper or `scripts/dev-build-and-launch.sh` so the app, CLI, and E2E helpers stay on the same worktree-scoped profile.
- When working from a repo-local checkout and other worktrees may also be running Spaces, bind your shell to the current worktree profile before using the debug app, `spaces`, or `spacese2e`: `eval "$(apps/macos/.build/debug/spaces profile show --shell)"`.
- Treat other worktrees' running Spaces instances as separate profiles. Do not kill them just to unblock your own workflow; only stop the app instance for the current profile, and let desktop-global verification wait for desktop control when another profile owns it.

## Ghostty Dependency Workflow
- The Ghostty fork is tracked as a git submodule at `apps/macos/vendor/ghostty` on the fork's `spaces` branch.
- The submodule gitlink is the single source of truth for the Ghostty commit used by `GhosttyKit.xcframework` and `libghostty-vt`.
- Edit Ghostty in `apps/macos/vendor/ghostty`, commit and push fork changes to the fork's `spaces` branch, then update the parent repo's submodule pointer in the normal Spaces pull request that depends on that Ghostty change.
- PR checks and Spaces app releases consume Spaces-owned prebuilt artifacts from a GitHub release named `ghostty-artifacts-<full-ghostty-sha>` in this repo. Trusted same-repo PR, main-push, manual, and release workflows build from the pinned submodule and publish reusable artifacts when the matching release is missing or incomplete.
- Fork PR checks build missing Ghostty artifacts locally without publishing reusable releases.
- Local debugging may use `apps/macos/scripts/setup_ghostty.sh --build --allow-dirty` for uncommitted Ghostty experiments, but Spaces PR and release workflows must use committed Ghostty fork work.

## Verification Rules
- Consider adding or expanding tests before finalizing code changes.
- Run `scripts/verify.sh` for the normal macOS verification pass so lint, build, and coverage run sequentially.
- When running `git commit` via Codex, allow at least a 10-minute timeout so pre-commit checks can finish.

## Documentation Rules
- Keep docs concise and non-overlapping.
- Treat `README.md`, `docs/dev.md`, `docs/spec.md`, `docs/implementation.md`, and `docs/design.md` as current-state references, not changelogs; avoid temporal wording like "now", "no longer", "previously", "new", or "changed" when describing the intended steady state.
- Update `docs/spec.md` when UX or user-visible behavior changes.
- Update `docs/implementation.md` when data flow, persistence, implementation structure, or the rationale behind a design choice changes.
- Update `docs/design.md` when the visual system, reusable interaction patterns, or UI styling guidance changes.
- Update `README.md` when the product overview, feature list, or adoption pitch changes.
- Update `docs/dev.md` when development, build, deploy, or manual E2E workflows change.
- Update `apps/web/app/docs/content.ts` when docs navigation or summaries need to reflect new product docs.
- When behavior is added through the CLI, update CLI help and architecture docs in the same change.

## Data and Migration Rules
- Installed/default database path: `~/.spaces/spaces.db`.
- Repo-local development builds default to `~/.spaces-dev/profiles/spaces/<branch-slug>-<worktree-hash>/spaces.db`.
- Use additive, non-destructive migrations that preserve existing data.
- Never add any destructive migration or reset path that can remove existing projects or workspaces.

## GUI Rules
- UI should feel modern and compact.
- Follow `docs/design.md` when adding or updating UI.
- Use icons for obvious actions such as add or remove.
- Use text labels for actions that are not obvious.
- Use icons instead of text for status where practical.
- Show inline keyboard shortcuts for actions.
- Respect system dark and light mode.
- Use labeled inputs for configuration; do not require app-specific text formats.

## Web Rules
- `apps/web` must remain a fully static prerendered Next.js site.
- Use the shared color and typography tokens in `apps/web/app/globals.css` instead of hard-coded values.
- Keep marketing content in `apps/web/app/page.tsx` and docs content under `apps/web/app/docs`.
- Prefer static or server-rendered content; do not add runtime API dependencies unless explicitly requested.

## Swift Rules
- Always mark `@Observable` classes with `@MainActor`.
- Assume strict Swift concurrency.
- Prefer Swift-native and modern Foundation APIs.
- Do not use C-style number formatting in SwiftUI text.
- Prefer static member lookup where possible.
- Do not use old-style GCD like `DispatchQueue.main.async`.
- Filter user-entered text with `localizedStandardContains()`.
- Avoid force unwrap and force try unless failure is unrecoverable.

## Project Structure Rules
- Organize code by feature.
- Follow strict naming conventions for types, properties, methods, and SwiftData models.
- Keep types split into focused files instead of combining many unrelated types in one file.
- Prefer unit tests for core logic; use UI tests only when unit tests are not possible.
- Add comments only where they reduce real ambiguity.
- Never commit secrets.
