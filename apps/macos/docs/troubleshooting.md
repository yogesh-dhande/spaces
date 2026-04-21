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

Register the current directory as a workspace:
```bash
mx workspace import --title "debug" --tooltip "Local troubleshooting session"
```

Force a clean runtime restart:
```bash
mx workspace up --force-restart
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
