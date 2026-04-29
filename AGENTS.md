# AGENTS.md

## Purpose
- Use this file for coding workflow, verification, and implementation guardrails.
- Put product behavior in `apps/macos/spec.md`.
- Put data flow, persistence, and module structure in `apps/macos/docs/architecture.md`.
- Put UI design and interaction guidelines in `design.md`.
- Put repository development and deploy commands in `README.md`.

## Product Constraints
- `Spaces` is a macOS Swift app for orchestration of coding tools
- The CLI is named `spaces`.
- Workspaces map to captured window sets managed via yabai.
- Use yabai as the single source of truth for window IDs.
- Avoid window-level automation outside yabai
- Any project setting used during workspace creation or launch must be overridable per workspace after creation.
- Anything configurable in the GUI must also be configurable via `spaces`.

## Coding Agent Workflow
- If on the `main` branch, switch to a new branch before committing changes. When asked to push, commit, push, and create a PR if there isn't one already. Do not add a coding agent name as a prefix to the branch name or the PR title.
- Always start by ensuring a Spaces workspace exists by running `~/projects/spaces/apps/macos/.build/debug/spaces workspace import --title [text] --tooltip [text]` from the project root.
- Before manually launching a new Spaces app instance for debugging or profiling, close any existing Spaces instances so only one global hotkey listener is active.
- When blocked on user input or permissions, run `~/projects/spaces/apps/macos/.build/debug/spaces agent event --type waiting` before asking.
- When changes are ready for review, first run `~/projects/spaces/apps/macos/.build/debug/spaces workspace update --tooltip [text]`, then run `~/projects/spaces/apps/macos/.build/debug/spaces workspace up --restart`.

## Verification Rules
- Always run lint and build before finalizing macOS app changes.
- Run `scripts/coverage.sh` after changes unless the change is limited to `apps/web` or docs/comments.
- Whenever `scripts/coverage.sh` is run, report the overall coverage percentage.
- Whenever `scripts/coverage.sh` is run, also report module-level coverage percentages for major modules such as `streamctl`, `gui`, and `appctl`.
- Always consider adding or expanding tests before finalizing code changes.
- When fixing a bug, reproduce it first using the real system, `~/projects/spaces/apps/macos/.build/debug/spaces` cli, and/or database inspection when practical, then add a test, implement the fix, and confirm both the test and the real workflow.
- When running `git commit` via Codex, allow at least a 10-minute timeout so pre-commit checks can finish.

## Documentation Rules
- Keep docs short and non-overlapping.
- Treat `README.md`, `apps/macos/spec.md`, `apps/macos/docs/architecture.md`, and `design.md` as current-state references, not changelogs; avoid temporal wording like "now", "previously", "new", or "changed" when describing the intended steady state.
- Update `apps/macos/spec.md` when UX or user-visible behavior changes.
- Update `apps/macos/docs/architecture.md` when data flow, persistence, or implementation structure changes.
- Update `design.md` when the visual system, reusable interaction patterns, or UI styling guidance changes.
- Update `apps/macos/README.md` when development or release workflow changes.
- Update `apps/web/app/docs/content.ts` when docs navigation or summaries need to reflect new product docs.
- When behavior is added through the CLI, update CLI help and architecture docs in the same change.

## Data and Migration Rules
- Database path: `~/.spaces/spaces.db`.
- Never bump SQLite `schemaVersion` for additive or compatible changes.
- Use additive, non-destructive migrations that preserve existing data.
- Any destructive migration or reset path that can remove existing projects or workspaces requires explicit user approval.

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
