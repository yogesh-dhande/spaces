#!/usr/bin/env bash

# MUST BE SOURCED, NOT EXECUTED -- `source apps/macos/scripts/verify-prep.sh`, either from
# run_verify_steps() in verify.sh or from a CI job that then runs coverage.sh in the same shell.
#
# spaces_profile_eval_shell_env below does `eval "$(...)"` to export profile-scoped environment
# variables (e.g. SPACES_DEVICE_API_PORT) into the CALLING shell, and the
# `unset SPACES_DEVICE_API_PORT` at the end removes a variable from that same calling shell. A
# child script's environment changes never propagate back to its parent process, so running this
# file as its own `verify-prep.sh` process would silently drop both mutations and leave
# coverage.sh (which runs afterward in the same shell and depends on them) pointed at a stale or
# wrong profile.
#
# Resolve our own location rather than requiring the caller to pre-set these, so a CI job can
# source this file directly from the repo root the same way verify.sh sources it from apps/macos.
# The prep steps below expect apps/macos as the working directory; verify.sh has already cd'd
# there, so this is a no-op for it.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$root/../.." && pwd)"
cd "$root"

source "$repo_root/scripts/spaces-profile-helpers.sh"

# Stops the profile's Spaces app and spacesd daemon before the SwiftPM coverage build reuses the
# profile, so tests do not race a stale already-running instance. Set
# SPACES_VERIFY_KEEP_PROFILE_RUNTIME=1 to skip this (e.g. when a developer wants to keep poking at
# a running instance while iterating on verify.sh itself).
stop_current_profile_runtime_for_tests() {
  if [ "${SPACES_VERIFY_KEEP_PROFILE_RUNTIME:-0}" = "1" ]; then
    echo "Keeping current Spaces profile runtime for verification (SPACES_VERIFY_KEEP_PROFILE_RUNTIME=1)"
    return
  fi

  local cli="$root/.build/debug/spaces"
  if [ ! -x "$cli" ]; then
    return
  fi

  echo "Stopping current Spaces profile app and spacesd daemon before SwiftPM coverage..."
  (
    spaces_profile_stop_running_app "$cli" "${SPACES_VERIFY_PROFILE_STOP_TIMEOUT:-20}"
    spaces_profile_stop_terminal_service "$cli" "${SPACES_VERIFY_PROFILE_STOP_TIMEOUT:-20}"
  )
}

"$root/Tests/ios_simulator_lifecycle.sh"
"$root/Tests/silence_watchdog.sh"
"$root/Tests/setup_ghostty_xcode_mismatch_autobuild.sh"
"$root/Tests/setup_ghostty_cache_restore.sh"
"$root/Tests/ensure_ghostty_artifacts_key_drift.sh"
# Sync the local GhosttyKit/libghostty-vt artifacts to the pinned submodule before building. CI
# runs ensure_ghostty_artifacts.sh ahead of verify, but a local .local can drift from the pin
# (worktree .local copies, iOS/Linux builds swapping artifacts), which makes embedded-terminal
# tests silently run against the wrong libghostty and fail as if flaky. This is a no-op when the
# installed manifest already matches the pin and self-heals from the cache otherwise.
"$root/scripts/setup_ghostty.sh"
"$root/scripts/lint.sh"
# Build the product binaries the steps below use: release_bundle_signing.sh signs them, and the
# profile helpers and E2E lanes run .build/debug/spaces. This build is deliberately plain --
# coverage.sh builds the instrumented test tree in its own scratch path, so nothing ever
# instruments these executables and neither build invalidates the other's incremental state.
"$root/scripts/swiftpm.sh" build
"$root/Tests/release_bundle_signing.sh"
spaces_profile_eval_shell_env "$root/.build/debug/spaces"
stop_current_profile_runtime_for_tests
unset SPACES_DEVICE_API_PORT
