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

## spaces Diagnostics

List projects and create an explicit workspace:
```bash
spaces project list
spaces workspace create --project <project-id> --branch debug --title "debug"
```

Force a clean runtime restart:
```bash
spaces workspace restart --workspace <workspace-id>
```

## Runtime Logs

Process logs are stored under:
```
~/.spaces/runtime/<workspace-id>/*.log
```

Inspect a log:
```bash
tail -n 200 ~/.spaces/runtime/<workspace-id>/<process>.log
```
