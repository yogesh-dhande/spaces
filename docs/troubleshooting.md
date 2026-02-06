# Troubleshooting (Dev)

This document is for development-time diagnostics, especially around yabai and window capture.

## Yabai Basics

List all displays:
```bash
yabai -m query --displays
```

List all spaces:
```bash
yabai -m query --spaces
```

List windows in a space (by space index):
```bash
yabai -m query --windows --space 1
```

List all windows (all spaces):
```bash
yabai -m query --windows
```

Show the focused window:
```bash
yabai -m query --windows --window
```

## agentmux Diagnostics

Doctor report for all streams:
```bash
agentmux doctor
```

Doctor report for a project/stream:
```bash
agentmux doctor --project <name> --stream <name>
```

Capture + show (auto-captures on show):
```bash
agentmux show --project <name> --stream <name>
```

## Status Files

Status files are written per terminal window:
```
<worktree>/.agentmux/status/window-<id>.json
```

List status files:
```bash
find <worktree>/.agentmux/status -name "window-*.json" -print
```

Watch status updates:
```bash
while true; do date; find <worktree>/.agentmux/status -name "window-*.json" -print -exec cat {} \;; sleep 1; echo "----"; done
```
