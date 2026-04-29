#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
APP="$repo_root/apps/macos/.build/debug/SpacesApp"
LOG_FILE="/tmp/Spaces.log"
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
POST_LAUNCH_MONITOR_SECONDS="${MUXY_POST_LAUNCH_MONITOR_SECONDS:-45}"

print_failure_diagnostics() {
  echo "Spaces exited; last log lines:"
  tail -n 80 "$LOG_FILE" || true
  if [ -d "$CRASH_DIR" ]; then
    latest_crash="$(ls -1t "$CRASH_DIR"/SpacesApp-*.ips "$CRASH_DIR"/SpacesApp-*.crash "$CRASH_DIR"/Spaces-*.ips "$CRASH_DIR"/Spaces-*.crash 2>/dev/null | head -n 1 || true)"
    if [ -n "$latest_crash" ]; then
      echo
      echo "Most recent crash report: $latest_crash"
      tail -n 120 "$latest_crash" || true
    fi
  fi
  echo
  echo "Recent unified logs:"
  /usr/bin/log show --style compact --last 2m --predicate 'process == "SpacesApp" OR process == "Spaces"' | tail -n 120 || true
}

# Kill any running instance before relaunching.
pkill -f "$APP" 2>/dev/null || true

"$repo_root/scripts/swiftpm.sh" build

# Relaunch in background and keep logs so launch failures are visible.
rm -f "$LOG_FILE"
nohup "$APP" >"$LOG_FILE" 2>&1 </dev/null &
app_pid=$!

# Bring app to front when possible.
for _ in $(seq 1 12); do
  if kill -0 "$app_pid" 2>/dev/null; then
    break
  fi
  sleep 0.5
done

if ! kill -0 "$app_pid" 2>/dev/null; then
  echo "Spaces exited immediately."
  print_failure_diagnostics
  exit 1
fi

osascript -e "tell application \"System Events\" to set frontmost of first process whose unix id is $app_pid to true" >/dev/null 2>&1 || true

echo "Spaces relaunched (pid $app_pid)"

if [ "$POST_LAUNCH_MONITOR_SECONDS" -gt 0 ]; then
  echo "Monitoring launch stability for ${POST_LAUNCH_MONITOR_SECONDS}s..."
  for _ in $(seq 1 "$POST_LAUNCH_MONITOR_SECONDS"); do
    if ! kill -0 "$app_pid" 2>/dev/null; then
      echo "Spaces exited during post-launch monitoring window."
      print_failure_diagnostics
      exit 1
    fi
    sleep 1
  done
  echo "Spaces stayed running for ${POST_LAUNCH_MONITOR_SECONDS}s after launch."
fi
