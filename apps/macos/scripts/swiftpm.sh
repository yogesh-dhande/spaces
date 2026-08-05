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

# A test run gets a throwaway profile for its whole lifetime. Profile resolution refuses the installed
# profile in a test process, and the developer's worktree profile is live state the debug app serves, so
# neither is a legitimate target for tests. Suites that scope the profile per test restore this value
# rather than clearing it, which is what keeps a suite that restores mid-run from stranding a concurrent
# suite with no profile at all — Swift Testing runs distinct suites in parallel in one process.
if [ "${1:-}" = "test" ]; then
  test_profile_dir="$root/.build/test-profile"
  rm -rf "$test_profile_dir"
  mkdir -p "$test_profile_dir"
  SPACES_DB_PATH="$test_profile_dir/spaces.db"
  export SPACES_DB_PATH
  # The runtime root derives from the database path, so an inherited override would leave the run half
  # bound: sockets, locks, and session directories in one profile while the database is in another. Tests
  # that scope a profile per test set only the database path and get a matching runtime root for free.
  unset SPACES_RUNTIME_DIR
fi

xcrun swift "$@" \
  --cache-path "$cache_dir" \
  --config-path "$config_dir" \
  --security-path "$security_dir"

exit $?
