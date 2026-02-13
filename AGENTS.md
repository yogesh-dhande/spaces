# AGENTS.md

## Purpose
- `spaceship` is a macOS Swift app for stream-based workspace orchestration.
- Streams map to **captured window sets** managed via yabai.
- The macOS app source lives under `apps/macos`.
- The marketing/docs website source lives under `apps/web`.

## Contributor Contract
- Use yabai as the single source of truth for window IDs.
- Stream capture is required before show.
- Avoid window-level automation outside yabai.
- Do not add backward compatibility layers unless explicitly requested.

## Data & Paths
- DB path: `~/.spaceship/spaceship.db` (managed automatically).
- Schema and architecture details live in `apps/macos/docs/architecture.md`.

## GUI
- UI design should be modern and compact
- Use icons for obvious actions (add/remove). Use text labels for actions that are not obvious.
- Use icons instead of text for status
- Show inline keyboard shortcuts for actions
- respect system dark/light mode settings
- Use labeled input fields for configuration; do not require users to enter app-specific text formats.

## Working Rules
- Build with `scripts/swiftpm.sh build` before finishing changes (workspace-local SwiftPM cache).
- Always run `scripts/swiftpm.sh build` after making changes.
- Always run `scripts/coverage.sh` after making changes.
- Exception: when changes are limited to `apps/web` only, skip `scripts/swiftpm.sh build` and `scripts/coverage.sh`.
- Whenever `scripts/coverage.sh` is run, always report the overall coverage percentage in the response.
- When running `git commit` via Codex, allow at least a 10-minute command timeout so pre-commit lint/coverage checks are not interrupted; this is a safety ceiling, not an expected runtime.
- Always consider adding or expanding tests to increase coverage before finalizing changes.
- Whenever changes are made to the macOS app, keep `apps/macos/spec.md`, `apps/macos/docs/architecture.md`, `apps/macos/docs/checkpoint.md`, and `apps/macos/README.md` up to date in the same change.
- Keep changes local-first and deterministic.
- When adding behavior, update CLI help and architecture docs in the same change.

## Web instructions
- `apps/web` must stay a fully static prerendered site (`next build` with export output).
- Use Next.js App Router with TypeScript and Tailwind CSS.
- Keep marketing content in `apps/web/app/page.tsx` and docs content under `apps/web/app/docs`.
- Prefer static/server-rendered content; avoid adding runtime API dependencies unless explicitly requested.
- When changing `apps/web`, run `npm run build` from `apps/web` to verify output.
- When changes are limited to `apps/web`, macOS Swift build/coverage checks are not required.


## Swift instructions
Always mark @Observable classes with @MainActor.
Assume strict Swift concurrency rules are being applied.
Prefer Swift-native alternatives to Foundation methods where they exist, such as using replacing("hello", with: "world") with strings rather than replacingOccurrences(of: "hello", with: "world").
Prefer modern Foundation API, for example URL.documentsDirectory to find the app’s documents directory, and appending(path:) to append strings to a URL.
Never use C-style number formatting such as Text(String(format: "%.2f", abs(myNumber))); always use Text(abs(change), format: .number.precision(.fractionLength(2))) instead.
Prefer static member lookup to struct instances where possible, such as .circle rather than Circle(), and .borderedProminent rather than BorderedProminentButtonStyle().
Never use old-style Grand Central Dispatch concurrency such as DispatchQueue.main.async(). If behavior like this is needed, always use modern Swift concurrency.
Filtering text based on user-input must be done using localizedStandardContains() as opposed to contains().
Avoid force unwraps and force try unless it is unrecoverable.


## Project structure
Use a consistent project structure, with folder layout determined by app features.
Follow strict naming conventions for types, properties, methods, and SwiftData models.
Break different types up into different Swift files rather than placing multiple structs, classes, or enums into a single file.
Write unit tests for core application logic.
Only write UI tests if unit tests are not possible.
Add code comments and documentation comments as needed.
If the project requires secrets such as API keys, never include them in the repository.
