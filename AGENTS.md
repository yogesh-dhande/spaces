# AGENTS.md

## Purpose
- Use this file for coding workflow, verification, and implementation guardrails.
- Put product behavior from the user's point of view in `apps/macos/spec.md`.
- Put implementation details and the rationale behind design choices in `apps/macos/docs/architecture.md`.
- Put UI design and interaction guidelines in `design.md`.
- Put product overview and adoption pitch in `README.md`.
- Put repository development, build, and deploy workflows in `dev.md`.

## Product Constraints
- `Spaces` is a macOS Swift app for orchestration of coding tools
- The CLI is named `spaces`.
- Workspaces map to captured window sets managed via yabai.
- Use yabai as the single source of truth for window IDs.
- Avoid window-level automation outside yabai
- Any project setting used during workspace creation or launch must be overridable per workspace after creation.
- Workspace-oriented runtime actions and metadata that the CLI supports must stay available via `spaces`, but app-level configuration is managed in the app rather than through `spaces`.

## Coding Agent Workflow
- If on the `main` branch, switch to a new branch before committing changes. When asked to push, commit, push, and create a PR if there isn't one already. Do not add a coding agent name as a prefix to the branch name or the PR title. Please check the PR status before pushing to existing branches with previously opened PRs. If the PR is closed, create a new branch and a new PR.
- When fixing a bug, reproduce it first using the real system, `~/projects/spaces/apps/macos/.build/debug/spaces` cli, and/or database inspection when practical, then add a test, implement the fix, and confirm both the test and the real workflow.
- Use the real-system scripts for hotkey-sensitive verification before resorting to ad hoc manual app launches. Those scripts may wait for desktop control instead of killing unrelated running Spaces instances.
- When manually launching a repo-local debug build, use the derived profile helper or `scripts/dev-build-and-launch.sh` so the app, CLI, and E2E helpers stay on the same worktree-scoped profile.
- When working from a repo-local checkout and other worktrees may also be running Spaces, bind your shell to the current worktree profile before using the debug app, `spaces`, or `spacese2e`: `eval "$(apps/macos/.build/debug/spaces profile show --shell)"`.
- Treat other worktrees' running Spaces instances as separate profiles. Do not kill them just to unblock your own workflow; only stop the app instance for the current profile, and let desktop-global verification wait for desktop control when another profile owns it.

## GhosttyKit Dependency Workflow
- The Ghostty fork publishes a GitHub release for every committed update to its `spaces` branch.
- Use `ghosttykit-<full-ghostty-sha>` as the GhosttyKit release tag in `apps/macos/ghosttykit-release-tag.txt`, and use the matching full Ghostty commit SHA in `apps/macos/ghosttyvt-revision.txt`.
- Update those pin files in the normal Spaces pull request that depends on the Ghostty change. Do not use a Spaces-side scheduled or auto-sync workflow to advance the pin.
- Spaces CI and Spaces app releases must consume those SHA-derived GhosttyKit release assets. Do not depend on uncommitted Ghostty work.
- Local debugging may build GhosttyKit from uncommitted changes in the local Ghostty checkout with `SPACES_GHOSTTYKIT_BUILD_FROM_SOURCE=1`, but commit and push Ghostty changes to the fork's `spaces` branch before making Spaces PRs depend on them.
- Before updating the Spaces pin or calling a GhosttyKit fix ready, check the Ghostty fork and any `apps/macos/.local/ghosttyvt/src` checkout for uncommitted or unpushed changes. Move any needed `.local` patch into the fork checkout, commit it, push it, and consume the resulting SHA release.
- If Spaces CI cannot find or verify the GhosttyKit release for the pinned SHA, fix or publish the Ghostty fork release instead of changing Spaces CI to build Ghostty from source.

## Verification Rules
- Always run lint and build before finalizing macOS app changes.
- Run `scripts/coverage.sh` after changes unless the change is limited to `apps/web` or docs/comments.
- Prefer `scripts/verify.sh` for the normal macOS verification pass so lint, build, and coverage run sequentially.
- Treat `scripts/lint.sh` as read-only verification. Use `scripts/format.sh` for explicit tree-wide formatting, and rely on `.githooks/pre-commit` to format staged Swift files before commit.
- `scripts/swiftpm.sh` is guarded by a fail-fast lock. Do not start overlapping build, test, or coverage runs; rerun after the active workflow finishes.
- Whenever `scripts/coverage.sh` is run, report the overall coverage percentage.
- Whenever `scripts/coverage.sh` is run, also report module-level coverage percentages for major modules such as systembridge, workspacecore, spacescli, etc.
- Consider adding or expanding tests before finalizing code changes.
- When running `git commit` via Codex, allow at least a 10-minute timeout so pre-commit checks can finish.

## Documentation Rules
- Keep docs short and non-overlapping.
- Treat `README.md`, `dev.md`, `apps/macos/spec.md`, `apps/macos/docs/architecture.md`, and `design.md` as current-state references, not changelogs; avoid temporal wording like "now", "previously", "new", or "changed" when describing the intended steady state.
- Update `apps/macos/spec.md` when UX or user-visible behavior changes.
- Update `apps/macos/docs/architecture.md` when data flow, persistence, implementation structure, or the rationale behind a design choice changes.
- Update `design.md` when the visual system, reusable interaction patterns, or UI styling guidance changes.
- Update `README.md` when the product overview, feature list, or adoption pitch changes.
- Update `dev.md` when development, build, deploy, or manual E2E workflows change.
- Update `apps/web/app/docs/content.ts` when docs navigation or summaries need to reflect new product docs.
- When behavior is added through the CLI, update CLI help and architecture docs in the same change.

## Data and Migration Rules
- Installed/default database path: `~/.spaces/spaces.db`.
- Repo-local development builds default to `~/.spaces-dev/profiles/spaces/<branch-slug>-<worktree-hash>/spaces.db`.
- Use additive, non-destructive migrations that preserve existing data.
- Never add any destructive migration or reset path that can remove existing projects or workspaces.

## GUI Rules
- UI should feel modern and compact.
- Follow `design.md` when adding or updating UI.
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
