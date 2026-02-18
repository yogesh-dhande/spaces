#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
APP="$repo_root/apps/macos/.build/debug/Muxy"
LOG_FILE="/tmp/Muxy.log"

# Kill any running instance before relaunching.
pkill -f "$APP" 2>/dev/null || true

"$repo_root/scripts/swiftpm.sh" build

# Relaunch in background and keep logs so launch failures are visible.
nohup "$APP" >"$LOG_FILE" 2>&1 &
app_pid=$!
sleep 1

# Bring app to front when possible.
osascript -e "tell application \"System Events\" to set frontmost of first process whose unix id is $app_pid to true" >/dev/null 2>&1 || true

if ! kill -0 "$app_pid" 2>/dev/null; then
  echo "Muxy exited immediately; last log lines:"
  tail -n 80 "$LOG_FILE" || true
  exit 1
fi

echo "Muxy relaunched (pid $app_pid)"
