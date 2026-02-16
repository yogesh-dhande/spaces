# Troubleshooting (Dev)

This document is for development-time diagnostics, especially around yabai and window focus.

## Yabai Basics

List displays:
```bash
yabai -m query --displays
```

List spaces:
```bash
yabai -m query --spaces
```

List all windows:
```bash
yabai -m query --windows
```

Show the focused window:
```bash
yabai -m query --windows --window
```

## muxy Diagnostics

Show config path:
```bash
mx config path
```

List projects:
```bash
mx project list
```

List workspaces (including archived):
```bash
mx workspace list --project-dir /path/to/repo --all
```

## Runtime Logs

Process logs are stored under:
```
~/.muxy/runtime/<workspace-id>/*.log
```

Inspect a log:
```bash
tail -n 200 ~/.muxy/runtime/<workspace-id>/<process>.log
```
