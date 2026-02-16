#!/usr/bin/env bash
set -euo pipefail

# Example usage:
# ./agentwrap.sh codex

INACTIVITY_THRESHOLD="${INACTIVITY_THRESHOLD:-2}"  # seconds without new output => waiting_for_input
POLL_INTERVAL="${POLL_INTERVAL:-0.25}"
DEBUG_WRAP="${MUXY_WRAP_DEBUG:-0}"

now_iso() {
  # macOS-compatible ISO-ish timestamp
  date +"%Y-%m-%dT%H:%M:%S%z"
}

write_status() {
  local state="$1"
  local exit_code="${2:-null}"
  if [[ "$DEBUG_WRAP" == "1" ]]; then
    echo "wrap: write_status state=$state exit=$exit_code file=$STATUS_FILE" >&2
  fi

  cat > "${STATUS_FILE}.tmp" <<EOF
{
  "state": "$state",
  "timestamp": "$(now_iso)",
  "exit_code": $exit_code
}
EOF
  mv "${STATUS_FILE}.tmp" "${STATUS_FILE}"
}

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <command> [args...]" >&2
  exit 1
fi

CMD=( "$@" )

# Temp log file for `script` output
TMPDIR="$(mktemp -d)"
LOGFILE="$TMPDIR/typescript.log"
STATUS_FILE="${STATUS_FILE:-$TMPDIR/status.json}"
cleanup() { rm -rf "$TMPDIR" >/dev/null 2>&1 || true; }
trap cleanup EXIT

write_status "starting" "null" "launching: ${CMD[*]}"

# Monitor output growth in background (no piping, so interactive tools work)
(
  # Wait until logfile exists
  while [[ ! -f "$LOGFILE" ]]; do sleep 0.05; done

  local_last_change="$(date +%s)"
  local_last_size=0
  last_line=""

  while :; do
    # If script ended, break (parent will handle done/error)
    # We can’t reliably know script PID from here, so just keep monitoring until parent exits.
    size="$(stat -f%z "$LOGFILE" 2>/dev/null || echo 0)"
    now="$(date +%s)"

    if [[ "$size" -gt "$local_last_size" ]]; then
      local_last_change="$now"
      local_last_size="$size"

      # Best-effort last line
      last_line="$(tail -n 1 "$LOGFILE" 2>/dev/null || true)"
      write_status "working" "null" "$last_line"
    else
      if (( now - local_last_change >= INACTIVITY_THRESHOLD )); then
        last_line="$(tail -n 1 "$LOGFILE" 2>/dev/null || true)"
        write_status "waiting_for_input" "null" "$last_line"
      fi
    fi

    sleep "$POLL_INTERVAL"
  done
) &
MON_PID=$!

# Run the real command under a PTY using `script` in the FOREGROUND.
# This preserves interactive behavior (cursor position queries, prompts, etc.).
set +e
script -q "$LOGFILE" "${CMD[@]}"
EXIT_CODE=$?
set -e

# Stop monitor
kill "$MON_PID" >/dev/null 2>&1 || true

# Final status
last_line="$(tail -n 1 "$LOGFILE" 2>/dev/null || true)"
if [[ $EXIT_CODE -eq 0 ]]; then
  write_status "done" "$EXIT_CODE" "$last_line"
else
  write_status "error" "$EXIT_CODE" "$last_line"
fi

exit "$EXIT_CODE"
