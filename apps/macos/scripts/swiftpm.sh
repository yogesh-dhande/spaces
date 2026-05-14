#!/bin/sh
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cache_dir="$root/.build/spm-cache"
config_dir="$root/.build/spm-config"
security_dir="$root/.build/spm-security"
clang_cache_dir="$root/.build/clang-module-cache"
lock_dir="$root/.build/swiftpm-exec.lock"
pid_file="$lock_dir/pid"
cmd_file="$lock_dir/command"

mkdir -p "$cache_dir" "$config_dir" "$security_dir" "$clang_cache_dir"
export CLANG_MODULE_CACHE_PATH="$clang_cache_dir"

cleanup_lock() {
  rm -f "$pid_file" "$cmd_file"
  rmdir "$lock_dir" >/dev/null 2>&1 || true
}

acquire_lock() {
  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" >"$pid_file"
    printf '%s\n' "$*" >"$cmd_file"
    trap cleanup_lock EXIT INT TERM HUP
    return 0
  fi

  if [ -f "$pid_file" ]; then
    existing_pid="$(cat "$pid_file" 2>/dev/null || echo "")"
  else
    existing_pid=""
  fi

  if [ -n "$existing_pid" ] && kill -0 "$existing_pid" >/dev/null 2>&1; then
    existing_command="$(cat "$cmd_file" 2>/dev/null || echo "unknown command")"
    echo "Another SwiftPM workflow is already running (pid=$existing_pid): $existing_command" >&2
    echo "Run lint/build/coverage sequentially or use scripts/verify.sh." >&2
    exit 1
  fi

  rm -f "$pid_file" "$cmd_file"
  rmdir "$lock_dir" >/dev/null 2>&1 || true

  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" >"$pid_file"
    printf '%s\n' "$*" >"$cmd_file"
    trap cleanup_lock EXIT INT TERM HUP
    return 0
  fi

  echo "Unable to acquire SwiftPM workflow lock at $lock_dir" >&2
  exit 1
}

disable_sandbox=1
disable_automatic_resolution=1
for arg in "$@"; do
  if [ "$arg" = "--disable-sandbox" ]; then
    disable_sandbox=0
  fi
  if [ "$arg" = "--disable-automatic-resolution" ] || [ "$arg" = "--force-resolved-versions" ] || [ "$arg" = "--only-use-versions-from-resolved-file" ]; then
    disable_automatic_resolution=0
  fi
done

if [ "$disable_sandbox" -eq 1 ]; then
  set -- "$@" --disable-sandbox
fi
if [ "$disable_automatic_resolution" -eq 1 ]; then
  set -- "$@" --disable-automatic-resolution
fi

acquire_lock "$@"

xcrun swift "$@" \
  --cache-path "$cache_dir" \
  --config-path "$config_dir" \
  --security-path "$security_dir"

exit $?
