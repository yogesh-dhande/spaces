# AGENTS.md

## Purpose
- `agentmux` is a macOS Swift app for stream-based workspace orchestration.
- Projects use a unified window model (`editor|browser|terminal|custom`) configured per window entry.

## Contributor Contract
- Preserve deterministic window targeting and layout behavior.
- Target apps by bundle ID only (not display names).
- Keep editor launch/position failures blocking; browser/terminal failures best-effort.
- Prefer persisted stream identity over fuzzy matching.
- Avoid backward compatibility aliases unless explicitly requested.
- Keep terminal status flow intact:
  - terminal commands should run through the managed wrapper
  - status files stay minimal (`state`, `timestamp`)

## Data & Paths
- Default DB path: `~/.agentmux/agentmux.db` (`--db` override allowed).
- Schema and architecture details live in `docs/architecture.md`.
- Managed terminal wrapper: `~/.agentmux/bin/agentwrap.sh`
- Per-stream terminal statuses: `<worktree>/.agentmux/terminal-status/*.json`

## Working Rules
- Build with `swift build` before finishing changes.
- Keep changes local-first and deterministic.
- When adding behavior, update CLI help and architecture docs in the same change.
- For behavior changes, also keep `README.md`, `docs/checkpoint.md`, and `spec.md` aligned.
