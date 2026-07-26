#!/bin/bash
# Resource sampler for the installed Spaces stack.
#
#   sampler.sh <out.csv> <duration_seconds> [interval_seconds]
#
# Emits one CSV row per process per tick: CPU%, RSS, VSZ, threads, cumulative
# CPU time, plus profile-wide database/WAL sizes and the daemon's child count.
# File-descriptor counts are collected every 6th tick because `lsof` is slow.
#
# Analyse with awk rather than reading the CSV wholesale, e.g. the slope of
# daemon CPU against session count:
#   awk -F, 'NR>1 && $3=="daemon" {printf "%s %s%% %dMB\n",$2,$5,$6/1024}' out.csv
set -u

OUT="$1"
DUR="${2:-600}"
INT="${3:-5}"

APP_BIN="/Applications/Spaces.app/Contents/MacOS/SpacesApp"
DAEMON_BIN="$HOME/.spaces/bin/spacesd"
CADDY_BIN="/Applications/Spaces.app/Contents/Resources/caddy"

# Anchored so a repo-built spacesd in another worktree is never matched.
find_pid() { pgrep -f "^$1" | head -1; }

file_kb() { local s; s=$(stat -f %z "$1" 2>/dev/null || echo 0); echo $((s / 1024)); }

echo "ts,elapsed,name,pid,pcpu,rss_kb,vsz_kb,threads,fds,cputime,db_kb,wal_kb,shm_kb,daemon_children,loadavg" > "$OUT"

START=$(date +%s)
END=$((START + DUR))
tick=0

while [ "$(date +%s)" -lt "$END" ]; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START))
  DB_KB=$(file_kb "$HOME/.spaces/spaces.db")
  WAL_KB=$(file_kb "$HOME/.spaces/spaces.db-wal")
  SHM_KB=$(file_kb "$HOME/.spaces/spaces.db-shm")
  LOAD=$(sysctl -n vm.loadavg | awk '{print $2}')

  DAEMON_PID=$(find_pid "$DAEMON_BIN")
  CHILDREN=0
  [ -n "${DAEMON_PID:-}" ] && CHILDREN=$(pgrep -P "$DAEMON_PID" 2>/dev/null | wc -l | tr -d ' ')

  COLLECT_FDS=0
  [ $((tick % 6)) -eq 0 ] && COLLECT_FDS=1

  for spec in "app:$APP_BIN" "daemon:$DAEMON_BIN" "caddy:$CADDY_BIN"; do
    NAME="${spec%%:*}"
    BIN="${spec#*:}"
    PID=$(find_pid "$BIN")
    if [ -z "${PID:-}" ]; then
      echo "$NOW,$ELAPSED,$NAME,,,,,,,,$DB_KB,$WAL_KB,$SHM_KB,$CHILDREN,$LOAD" >> "$OUT"
      continue
    fi
    read -r PCPU RSS VSZ CPUTIME <<< "$(ps -p "$PID" -o %cpu=,rss=,vsz=,time= | awk '{print $1, $2, $3, $4}')"
    THREADS=$(ps -M -p "$PID" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    FDS=""
    [ "$COLLECT_FDS" -eq 1 ] && FDS=$(lsof -p "$PID" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    echo "$NOW,$ELAPSED,$NAME,$PID,$PCPU,$RSS,$VSZ,$THREADS,$FDS,$CPUTIME,$DB_KB,$WAL_KB,$SHM_KB,$CHILDREN,$LOAD" >> "$OUT"
  done

  tick=$((tick + 1))
  sleep "$INT"
done

echo "sampler finished: $OUT"
