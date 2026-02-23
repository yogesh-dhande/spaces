# AGENTS.md

## Purpose
- `Muxy` is a macOS Swift app for stream-based workspace orchestration.
- The CLI is named `mx`.
- Workspaces map to **captured window sets** managed via yabai.
- The macOS app source lives under `apps/macos`.
- The marketing/docs website source lives under `apps/web`.

## Contributor Contract
- Use yabai as the single source of truth for window IDs.
- Avoid window-level automation outside yabai, except iTerm2 tab/session selection via iTerm2 AppleScript when focusing the correct terminal tab within iTerm2.
- Any project setting related to workspace creation and used during workspace launch must be overridable per workspace after creation.
- Anything configurable via the GUI must also be configurable via the CLI (`mx`). Keep the two in sync.

## Worktree Workflow
- Use the Muxy CLI `mx` to enhance user experience when working with worktrees.
- Whenever working on a worktree, ensure a Muxy workspace is created for the worktree by running `mx workspace import --name [text]` from the worktree directory.
- When code changes are ready for user review, always run `mx workspace up --tooltip [text]` to ensure the Muxy workspace is running and set a tooltip to provide sufficient context for the user about what is being worked on and the changes

## Data & Paths
- DB path: `~/.muxy/muxy.db` (managed automatically).
- Schema and architecture details live in `apps/macos/docs/architecture.md`.

## GUI
- UI design should be modern and compact
- Use icons for obvious actions (add/remove). Use text labels for actions that are not obvious.
- Use icons instead of text for status
- Show inline keyboard shortcuts for actions
- respect system dark/light mode settings
- Use labeled input fields for configuration; do not require users to enter app-specific text formats.

## Working Rules
- Always run lint and build before finalizing changes to the macos app.
- Run `scripts/coverage.sh` after making changes. Exception: when changes are limited to `apps/web` only.
- Whenever `scripts/coverage.sh` is run, always report the overall coverage percentage in the response.
- When running `git commit` via Codex, allow at least a 10-minute command timeout so pre-commit lint/coverage checks are not interrupted; this is a safety ceiling, not an expected runtime.
- Always consider adding or expanding tests to increase coverage before finalizing changes.
- Whenever changes are made to the macOS app, keep `apps/macos/spec.md`, `apps/macos/docs/architecture.md`, `apps/macos/README.md`, and the nextjs project docs (`apps/web/app/docs/content.ts`) up to date in the same change.
- Keep changes local-first and deterministic.
- When adding behavior, update CLI help and architecture docs in the same change.
- Database migration safety:
  - Never bump SQLite `schemaVersion` for additive/compatible DB changes.
  - Use non-destructive migrations (`CREATE TABLE IF NOT EXISTS`, `ALTER TABLE`, backfills) that preserve existing user data in `~/.muxy/muxy.db`.
  - Any destructive migration/reset path that can remove existing projects/workspaces requires explicit user approval.
- When fixing a bug, try to recreate and understand the bug first using the real system, mx cli, and database inspection on the dev computer. Write tests to catch the bug, then implement the fix. Run the tests and the real system check to confirm the fix before concluding whether the fix is sufficient.
## Web Color Palette
All web colors are defined as CSS custom properties in `apps/web/app/globals.css`.

### Semantic tokens (light / dark)
| Token             | Light       | Dark        | Usage                        |
|-------------------|-------------|-------------|------------------------------|
| `--bg`            | `#f8f7f1`   | `#0f1517`   | Page background              |
| `--bg-soft`       | `#f1efe6`   | `#172124`   | Secondary/gradient background|
| `--surface`       | `#ffffff`   | `#1d2a2d`   | Cards, panels, overlays      |
| `--ink`           | `#102028`   | `#eaf0ef`   | Primary text                 |
| `--ink-soft`      | `#3a4d57`   | `#adc0c4`   | Secondary/muted text         |
| `--line`          | `#d5d8d3`   | `#304346`   | Borders, dividers            |
| `--accent`        | `#0f7a76`   | `#59dbcd`   | Interactive/brand accent     |
| `--accent-strong` | `#0d5f5d`   | `#3dc6b8`   | CTAs, hover states           |

### Fixed role colors (unchanged across themes)
| Color     | Hex       | Role                          |
|-----------|-----------|-------------------------------|
| Blue      | `#1f73b8` | Browser pane tint             |
| Purple    | `#7354d8` | Editor pane tint              |
| Green     | `#19825a` | Terminal pane tint             |
| Rose      | `#ba436f` | Stop/destructive action, decorative gradient |
| Amber     | `#a86b00` | Restart/warning action        |
| Term text | `#98efc7` | Terminal body text            |
| Term bg   | `#0f1820` | Terminal body background      |

### Traffic-light dots
| Dot    | Hex       |
|--------|-----------|
| Red    | `#ff6f5b` |
| Yellow | `#f8c84f` / `#f0c14b` |
| Green  | `#35cf7a` / `#39c97b` |

### Typography
| Token         | Stack                                                  |
|---------------|--------------------------------------------------------|
| `--font-sans` | Avenir Next, Trebuchet MS, Segoe UI, sans-serif        |
| `--font-mono` | SFMono-Regular, Menlo, Consolas, monospace              |

When adding new UI elements, always reference these tokens instead of hard-coding hex values.

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
