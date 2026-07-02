# Troubleshooting (Dev)

This document is for development-time diagnostics around workspace runtime and window focus.

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

## Browser Sessions

- **Browser sessions don't open or focus Chrome** — Spaces controls Google Chrome through Apple Events, which macOS gates under the Automation permission. Enable Spaces for Google Chrome under System Settings ▸ Privacy & Security ▸ Automation. The first-run setup screen also links there directly.

## Runtime Logs

Process logs are stored under:
```
~/.spaces/runtime/<workspace-id>/*.log
```

Inspect a log:
```bash
tail -n 200 ~/.spaces/runtime/<workspace-id>/<process>.log
```
