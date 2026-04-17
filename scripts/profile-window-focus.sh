#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Config
# Update these values for the workspace and row order you want to profile.
# The default indices below match the dedicated-window banana demo workspace:
#   1 = first browser row
#   2 = second browser row
#   3 = first process/iTerm row
#   4 = second process/iTerm row
# -----------------------------------------------------------------------------
WORKSPACE_DIR="${WORKSPACE_DIR:-/Users/yogesh/muxy/workspaces/frontend-demo/banana}"
MUXY_APP="${MUXY_APP:-$(cd "$(dirname "$0")/.." && pwd)/apps/macos/.build/debug/Muxy}"
MX_BIN="${MX_BIN:-$(cd "$(dirname "$0")/.." && pwd)/apps/macos/.build/debug/mx}"
PROFILE_LOG="${PROFILE_LOG:-/tmp/muxy-window-focus-profile.log}"
SAMPLE_COUNT="${SAMPLE_COUNT:-3}"
ACTION_TIMEOUT_SECONDS="${ACTION_TIMEOUT_SECONDS:-8}"
POST_ACTION_SETTLE_SECONDS="${POST_ACTION_SETTLE_SECONDS:-0.35}"
POST_LAUNCH_SETTLE_SECONDS="${POST_LAUNCH_SETTLE_SECONDS:-1.5}"
BUILD_BEFORE_RUN="${BUILD_BEFORE_RUN:-1}"
RELAUNCH_DEBUG_APP="${RELAUNCH_DEBUG_APP:-0}"
KEEP_APP_RUNNING="${KEEP_APP_RUNNING:-1}"

MUXY_TO_BROWSER_INDEX="${MUXY_TO_BROWSER_INDEX:-1}"
MUXY_TO_ITERM_INDEX="${MUXY_TO_ITERM_INDEX:-3}"

BROWSER_TO_BROWSER_START_INDEX="${BROWSER_TO_BROWSER_START_INDEX:-1}"
BROWSER_TO_ITERM_START_INDEX="${BROWSER_TO_ITERM_START_INDEX:-2}"
ITERM_TO_ITERM_START_INDEX="${ITERM_TO_ITERM_START_INDEX:-3}"
ITERM_TO_BROWSER_START_INDEX="${ITERM_TO_BROWSER_START_INDEX:-4}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
search_from_line=1
launched_pid=""

cleanup() {
  if [[ -n "${launched_pid}" && "${KEEP_APP_RUNNING}" != "1" ]]; then
    kill "${launched_pid}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

require_file() {
  local path="$1"
  if [[ ! -x "${path}" ]]; then
    echo "Expected executable not found: ${path}" >&2
    exit 1
  fi
}

sleep_seconds() {
  perl -e "select undef, undef, undef, $1"
}

build_if_needed() {
  if [[ "${BUILD_BEFORE_RUN}" == "1" ]]; then
    "${repo_root}/scripts/swiftpm.sh" build >/dev/null
  fi
}

close_existing_muxy_instances() {
  osascript -e 'tell application "Muxy" to quit' >/dev/null 2>&1 || true
  pkill -x Muxy >/dev/null 2>&1 || true
  sleep 1
}

launch_debug_muxy() {
  : > "${PROFILE_LOG}"
  env DEBUG=1 "${MUXY_APP}" >"${PROFILE_LOG}" 2>&1 &
  launched_pid=$!

  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if kill -0 "${launched_pid}" >/dev/null 2>&1; then
      focus_muxy_app
      sleep_seconds "${POST_LAUNCH_SETTLE_SECONDS}"
      return 0
    fi
    sleep 0.2
  done

  echo "Failed to launch debug Muxy app." >&2
  exit 1
}

focus_muxy_app() {
  local pid="${launched_pid}"
  if [[ -z "${pid}" ]]; then
    pid="$(pgrep -x Muxy | tail -n 1)"
  fi
  if [[ -z "${pid}" ]]; then
    echo "Could not find a running Muxy process." >&2
    exit 1
  fi

  osascript -e "tell application \"System Events\" to set frontmost of first process whose unix id is ${pid} to true" >/dev/null
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if osascript -e "tell application \"System Events\" to unix id of first process whose frontmost is true" 2>/dev/null | grep -qx "${pid}"; then
      return 0
    fi
    sleep 0.1
  done
  echo "Timed out waiting for debug Muxy app to become frontmost." >&2
  exit 1
}

ensure_workspace_exists() {
  "${MX_BIN}" workspace import --dir "${WORKSPACE_DIR}" >/dev/null 2>&1 || true
}

wait_for_pattern() {
  local pattern="$1"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  local match

  while (( SECONDS < deadline )); do
    if [[ -f "${PROFILE_LOG}" ]]; then
      match="$(
        awk -v start="${search_from_line}" -v pattern="${pattern}" '
          NR >= start && $0 ~ pattern { print NR ":" $0; exit }
        ' "${PROFILE_LOG}"
      )"
      if [[ -n "${match}" ]]; then
        local line_number="${match%%:*}"
        local line="${match#*:}"
        search_from_line=$((line_number + 1))
        printf '%s\n' "${line}"
        return 0
      fi
    fi
    sleep 0.1
  done

  echo "Timed out waiting for log pattern: ${pattern}" >&2
  return 1
}

extract_metric() {
  local line="$1"
  local key="$2"
  sed -E "s/.*${key}=([0-9]+).*/\\1/" <<<"${line}"
}

send_cmd_number() {
  local index="$1"
  local key_code=""
  case "${index}" in
    1) key_code=18 ;;
    2) key_code=19 ;;
    3) key_code=20 ;;
    4) key_code=21 ;;
    5) key_code=23 ;;
    6) key_code=22 ;;
    7) key_code=26 ;;
    8) key_code=28 ;;
    9) key_code=25 ;;
    *)
      echo "Unsupported cmd+number index: ${index}" >&2
      exit 1
      ;;
  esac
  osascript -e "tell application \"System Events\" to key code ${key_code} using command down" >/dev/null
}

send_cycle_next() {
  osascript -e 'tell application "System Events" to key code 30 using {command down, shift down}' >/dev/null
}

focus_workspace_window() {
  local index="$1"
  "${MX_BIN}" workspace focus --dir "${WORKSPACE_DIR}" --window "${index}" >/dev/null
  sleep_seconds "${POST_ACTION_SETTLE_SECONDS}"
}

collect_direct_shortcut_sample() {
  local index="$1"
  focus_muxy_app
  send_cmd_number "${index}"
  local line
  line="$(wait_for_pattern "muxy: window_shortcut stage=total index=${index} elapsed_ms=")"
  sleep_seconds "${POST_ACTION_SETTLE_SECONDS}"
  extract_metric "${line}" "elapsed_ms"
}

collect_cycle_sample() {
  local start_index="$1"
  focus_workspace_window "${start_index}"
  send_cycle_next
  local line
  line="$(wait_for_pattern "muxy: cycle workspace=.* direction=next total_ms=[0-9]+ target=.* success=1")"
  sleep_seconds "${POST_ACTION_SETTLE_SECONDS}"
  extract_metric "${line}" "total_ms"
}

summarize_samples() {
  local action_name="$1"
  local samples_file="$2"
  awk -v action="${action_name}" '
    BEGIN {
      min = -1
      max = 0
      total = 0
      count = 0
      raw = ""
    }
    {
      value = $1 + 0
      total += value
      count += 1
      if (min < 0 || value < min) min = value
      if (value > max) max = value
      raw = raw (raw == "" ? "" : ",") value
    }
    END {
      avg = count > 0 ? total / count : 0
      printf "%-24s avg=%6.1fms  min=%4dms  max=%4dms  samples=[%s]\n", action, avg, min, max, raw
    }
  ' "${samples_file}"
}

main() {
  require_file "${MUXY_APP}"
  require_file "${MX_BIN}"
  build_if_needed
  ensure_workspace_exists

  if [[ "${RELAUNCH_DEBUG_APP}" == "1" ]]; then
    close_existing_muxy_instances
    launch_debug_muxy
  else
    focus_muxy_app
    : > "${PROFILE_LOG}"
  fi

  local muxy_to_browser_samples
  local muxy_to_iterm_samples
  local browser_to_browser_samples
  local browser_to_iterm_samples
  local iterm_to_iterm_samples
  local iterm_to_browser_samples
  muxy_to_browser_samples="$(mktemp)"
  muxy_to_iterm_samples="$(mktemp)"
  browser_to_browser_samples="$(mktemp)"
  browser_to_iterm_samples="$(mktemp)"
  iterm_to_iterm_samples="$(mktemp)"
  iterm_to_browser_samples="$(mktemp)"

  for _ in $(seq 1 "${SAMPLE_COUNT}"); do collect_direct_shortcut_sample "${MUXY_TO_BROWSER_INDEX}" >>"${muxy_to_browser_samples}"; done
  for _ in $(seq 1 "${SAMPLE_COUNT}"); do collect_direct_shortcut_sample "${MUXY_TO_ITERM_INDEX}" >>"${muxy_to_iterm_samples}"; done
  for _ in $(seq 1 "${SAMPLE_COUNT}"); do collect_cycle_sample "${BROWSER_TO_BROWSER_START_INDEX}" >>"${browser_to_browser_samples}"; done
  for _ in $(seq 1 "${SAMPLE_COUNT}"); do collect_cycle_sample "${BROWSER_TO_ITERM_START_INDEX}" >>"${browser_to_iterm_samples}"; done
  for _ in $(seq 1 "${SAMPLE_COUNT}"); do collect_cycle_sample "${ITERM_TO_ITERM_START_INDEX}" >>"${iterm_to_iterm_samples}"; done
  for _ in $(seq 1 "${SAMPLE_COUNT}"); do collect_cycle_sample "${ITERM_TO_BROWSER_START_INDEX}" >>"${iterm_to_browser_samples}"; done

  echo
  echo "Window focus profile summary"
  echo "workspace: ${WORKSPACE_DIR}"
  echo "samples per action: ${SAMPLE_COUNT}"
  echo "log file: ${PROFILE_LOG}"
  echo
  summarize_samples "muxy_to_browser" "${muxy_to_browser_samples}"
  summarize_samples "muxy_to_iterm" "${muxy_to_iterm_samples}"
  summarize_samples "browser_to_browser" "${browser_to_browser_samples}"
  summarize_samples "browser_to_iterm" "${browser_to_iterm_samples}"
  summarize_samples "iterm_to_iterm" "${iterm_to_iterm_samples}"
  summarize_samples "iterm_to_browser" "${iterm_to_browser_samples}"
}

main "$@"
