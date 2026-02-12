# AGENTS.md

## Purpose
- `agentmux` is a macOS Swift app for stream-based workspace orchestration.
- Streams map to **captured window sets** managed via yabai.

## Contributor Contract
- Use yabai as the single source of truth for window IDs.
- Stream capture is required before show.
- Avoid window-level automation outside yabai.
- Do not add backward compatibility layers unless explicitly requested.

## Data & Paths
- DB path: `~/.agentmux/agentmux.db` (managed automatically).
- Schema and architecture details live in `docs/architecture.md`.

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
- Whenever `scripts/coverage.sh` is run, always report the overall coverage percentage in the response.
- When running `git commit` via Codex, allow at least a 10-minute command timeout so pre-commit lint/coverage checks are not interrupted; this is a safety ceiling, not an expected runtime.
- When creating commits via Codex, exclude `future.md` unless the user explicitly asks to include it.
- Always consider adding or expanding tests to increase coverage before finalizing changes.
- Before committing changes, always ensure `spec.md`, `docs/architecture.md`, `docs/checkpoint.md`, and `README.md` are also updated as appropriate.
- Keep changes local-first and deterministic.
- When adding behavior, update CLI help and architecture docs in the same change.


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
