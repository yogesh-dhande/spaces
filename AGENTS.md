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

## Working Rules
- Build with `swift build` before finishing changes.
- Always run `swift build` after making changes.
- Keep changes local-first and deterministic.
- When adding behavior, update CLI help and architecture docs in the same change.
- For behavior changes, also keep `README.md`, `docs/checkpoint.md`, and `spec.md` aligned.
