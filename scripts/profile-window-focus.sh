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
WORKSPACE_DIR="${WORKSPACE_DIR:-/Users/yogesh/spaces/workspaces/frontend-demo/banana}"
SPACES_APP="${SPACES_APP:-$(cd "$(dirname "$0")/.." && pwd)/apps/macos/.build/debug/SpacesApp}"
MX_BIN="${MX_BIN:-$(cd "$(dirname "$0")/.." && pwd)/apps/macos/.build/debug/spaces}"
PROFILE_LOG="${PROFILE_LOG:-/tmp/spaces-window-focus-profile.log}"
SAMPLE_COUNT="${SAMPLE_COUNT:-3}"
STARTUP_SAMPLE_COUNT="${STARTUP_SAMPLE_COUNT:-3}"
ACTION_TIMEOUT_SECONDS="${ACTION_TIMEOUT_SECONDS:-8}"
POST_ACTION_SETTLE_SECONDS="${POST_ACTION_SETTLE_SECONDS:-0.35}"
POST_LAUNCH_SETTLE_SECONDS="${POST_LAUNCH_SETTLE_SECONDS:-1.5}"
STARTUP_RETRY_INTERVAL_SECONDS="${STARTUP_RETRY_INTERVAL_SECONDS:-0.2}"
BUILD_BEFORE_RUN="${BUILD_BEFORE_RUN:-1}"
RELAUNCH_DEBUG_APP="${RELAUNCH_DEBUG_APP:-0}"
KEEP_APP_RUNNING="${KEEP_APP_RUNNING:-1}"
ENABLE_STARTUP_PROFILE="${ENABLE_STARTUP_PROFILE:-1}"

SPACES_TO_BROWSER_INDEX="${SPACES_TO_BROWSER_INDEX:-1}"
SPACES_TO_ITERM_INDEX="${SPACES_TO_ITERM_INDEX:-3}"
STARTUP_SHORTCUT_INDEX="${STARTUP_SHORTCUT_INDEX:-${SPACES_TO_BROWSER_INDEX}}"
SETUP_CHECK_IDS=(iterm2Installed tmuxInstalled yabaiInstalled yabaiServiceRunning yabaiAccessibility)

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

close_existing_spaces_instances() {
  osascript -e 'tell application "Spaces" to quit' >/dev/null 2>&1 || true
  pkill -x SpacesApp >/dev/null 2>&1 || true
  sleep 1
}

launch_debug_spaces() {
  : > "${PROFILE_LOG}"
  search_from_line=1
  env DEBUG=1 SPACES_STARTUP_PROFILE="${ENABLE_STARTUP_PROFILE}" "${SPACES_APP}" >"${PROFILE_LOG}" 2>&1 &
  launched_pid=$!

  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if kill -0 "${launched_pid}" >/dev/null 2>&1; then
      focus_spaces_app
      sleep_seconds "${POST_LAUNCH_SETTLE_SECONDS}"
      return 0
    fi
    sleep 0.2
  done

  echo "Failed to launch debug Spaces app." >&2
  exit 1
}

focus_spaces_app() {
  local pid="${launched_pid}"
  if [[ -z "${pid}" ]]; then
    pid="$(pgrep -x SpacesApp | tail -n 1)"
  fi
  if [[ -z "${pid}" ]]; then
    echo "Could not find a running Spaces process." >&2
    exit 1
  fi

  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    osascript -e "tell application \"System Events\" to set frontmost of first process whose unix id is ${pid} to true" >/dev/null 2>&1 || true
    if osascript -e "tell application \"System Events\" to unix id of first process whose frontmost is true" 2>/dev/null | grep -qx "${pid}"; then
      return 0
    fi
    sleep 0.1
  done
  echo "Timed out waiting for debug Spaces app to become frontmost." >&2
  exit 1
}

ensure_workspace_exists() {
  "${MX_BIN}" workspace import --dir "${WORKSPACE_DIR}" >/dev/null 2>&1 || true
}

wait_for_pattern() {
  local pattern="$1"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    if find_new_pattern_once "${pattern}"; then return 0; fi
    sleep 0.1
  done

  echo "Timed out waiting for log pattern: ${pattern}" >&2
  return 1
}

find_new_pattern_once() {
  local pattern="$1"
  local match
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
  return 1
}

find_pattern_anywhere() {
  local pattern="$1"
  if [[ -f "${PROFILE_LOG}" ]]; then
    awk -v pattern="${pattern}" '$0 ~ pattern { print; exit }' "${PROFILE_LOG}"
  fi
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
  focus_spaces_app
  send_cmd_number "${index}"
  local line
  line="$(wait_for_pattern "spaces: window_shortcut stage=total index=${index} elapsed_ms=")"
  sleep_seconds "${POST_ACTION_SETTLE_SECONDS}"
  extract_metric "${line}" "elapsed_ms"
}

collect_cycle_sample() {
  local start_index="$1"
  focus_workspace_window "${start_index}"
  send_cycle_next
  local line
  line="$(wait_for_pattern "spaces: cycle workspace=.* direction=next total_ms=[0-9]+ target=.* success=1")"
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

collect_startup_first_interaction_sample() {
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    focus_spaces_app
    send_cmd_number "${STARTUP_SHORTCUT_INDEX}"
    local line=""
    line="$(find_new_pattern_once "spaces: startup stage=first_interaction elapsed_ms=" || true)"
    if [[ -n "${line}" ]]; then
      sleep_seconds "${POST_ACTION_SETTLE_SECONDS}"
      extract_metric "${line}" "elapsed_ms"
      return 0
    fi
    sleep_seconds "${STARTUP_RETRY_INTERVAL_SECONDS}"
  done

  echo "Timed out waiting for first startup interaction." >&2
  return 1
}

collect_startup_sample() {
  close_existing_spaces_instances
  launch_debug_spaces

  local shell_window_line
  local shortcut_monitor_line
  local setup_complete_line
  local main_content_line
  local workspace_scan_breakdown_line
  local workspace_scan_line
  local dashboard_snapshot_line
  local snapshot_complete_line
  local apply_selection_line
  local first_interaction_ms

  shell_window_line="$(wait_for_pattern "spaces: startup stage=shell_window_ready elapsed_ms=")"
  shortcut_monitor_line="$(wait_for_pattern "spaces: startup stage=shortcut_monitor_ready elapsed_ms=")"
  setup_complete_line="$(wait_for_pattern "spaces: startup stage=setup_complete elapsed_ms=")"
  main_content_line="$(wait_for_pattern "spaces: startup stage=main_content_ready elapsed_ms=")"
  workspace_scan_breakdown_line="$(wait_for_pattern "spaces: startup stage=sidebar_snapshot_workspace_scan_breakdown elapsed_ms=")"
  workspace_scan_line="$(wait_for_pattern "spaces: startup stage=sidebar_snapshot_workspace_scan_ready elapsed_ms=")"
  dashboard_snapshot_line="$(wait_for_pattern "spaces: startup stage=sidebar_snapshot_dashboard_ready elapsed_ms=")"
  snapshot_complete_line="$(wait_for_pattern "spaces: startup stage=sidebar_snapshot_complete elapsed_ms=")"
  apply_selection_line="$(wait_for_pattern "spaces: startup stage=apply_snapshot_selection_ready elapsed_ms=")"
  first_interaction_ms="$(collect_startup_first_interaction_sample)"

  local setup_check_metrics
  setup_check_metrics="$(collect_setup_check_sample)"
  local git_activity_metrics
  git_activity_metrics="$(collect_git_activity_sample)"

  printf '%s %s %s %s %s %s %s %s %s %s %s %s %s %s\n' \
    "${setup_check_metrics}" \
    "$(extract_metric "${shell_window_line}" "elapsed_ms")" \
    "$(extract_metric "${shortcut_monitor_line}" "elapsed_ms")" \
    "$(extract_metric "${setup_complete_line}" "elapsed_ms")" \
    "$(extract_metric "${main_content_line}" "elapsed_ms")" \
    "$(extract_metric "${workspace_scan_breakdown_line}" "list_ms")" \
    "$(extract_metric "${workspace_scan_breakdown_line}" "runtime_ms")" \
    "$(extract_metric "${workspace_scan_breakdown_line}" "git_ms")" \
    "$(extract_metric "${workspace_scan_line}" "elapsed_ms")" \
    "$(extract_metric "${dashboard_snapshot_line}" "elapsed_ms")" \
    "$(extract_metric "${snapshot_complete_line}" "elapsed_ms")" \
    "$(extract_metric "${apply_selection_line}" "elapsed_ms")" \
    "${first_interaction_ms}" \
    "${git_activity_metrics}"
}

summarize_startup_samples() {
  local samples_file="$1"
  awk '
    function fmt(label, value) {
      printf "%-24s avg=%6.1fms\n", label, value
    }
    {
      shell += $12
      shortcut += $13
      setup += $14
      content += $15
      scan_list += $16
      scan_runtime += $17
      scan_git += $18
      scan += $19
      dashboard += $20
      snapshot += $21
      apply += $22
      input += $23
      git_workspace_count += $24
      git_repo_check += $25
      git_tracked_paths += $26
      git_latest_mod += $27
      git_modified_count += $28
      git_base_ref += $29
      git_ahead_behind += $30
      git_merge_conflicts += $31
      git_total += $32
      scan_phase += ($19 - $15)
      scan_other += ($19 - $15 - $16 - $17 - $18)
      dashboard_phase += ($20 - $19)
      snapshot_tail += ($21 - $20)
      apply_phase += ($22 - $21)
      interaction_tail += ($23 - $22)
      count += 1
    }
    END {
      if (count == 0) exit 0
      fmt("window_visible", shell / count)
      fmt("shortcut_monitor_ready", shortcut / count)
      fmt("setup_complete", setup / count)
      fmt("main_content_ready", content / count)
      fmt("workspace_scan_ready", scan / count)
      fmt("dashboard_snapshot_ready", dashboard / count)
      fmt("snapshot_complete", snapshot / count)
      fmt("selection_ready", apply / count)
      fmt("first_interaction", input / count)
      print ""
      fmt("phase_scan_list_workspaces", scan_list / count)
      fmt("phase_scan_runtime_status", scan_runtime / count)
      fmt("phase_scan_git_activity", scan_git / count)
      fmt("phase_snapshot_scan", scan_phase / count)
      fmt("phase_scan_other", scan_other / count)
      print ""
      printf "%-24s avg=%6.1f\n", "git_activity_workspaces", git_workspace_count / count
      fmt("git_activity_repo_check", git_repo_check / count)
      fmt("git_activity_tracked_paths", git_tracked_paths / count)
      fmt("git_activity_latest_mod", git_latest_mod / count)
      fmt("git_activity_modified_count", git_modified_count / count)
      fmt("git_activity_base_ref", git_base_ref / count)
      fmt("git_activity_ahead_behind", git_ahead_behind / count)
      fmt("git_activity_merge_conflicts", git_merge_conflicts / count)
      fmt("git_activity_total", git_total / count)
      print ""
      fmt("phase_dashboard_build", dashboard_phase / count)
      fmt("phase_snapshot_tail", snapshot_tail / count)
      fmt("phase_main_thread_apply", apply_phase / count)
      fmt("phase_input_after_ready", interaction_tail / count)
    }
  ' "${samples_file}"
}

collect_git_activity_sample() {
  awk '
    /spaces: git_activity workspace=/ {
      count += 1
      for (i = 1; i <= NF; i += 1) {
        if ($i ~ /^repo_check_ms=/) repo += substr($i, 15) + 0
        else if ($i ~ /^tracked_paths_ms=/) tracked += substr($i, 18) + 0
        else if ($i ~ /^latest_mod_ms=/) latest += substr($i, 15) + 0
        else if ($i ~ /^modified_count_ms=/) modified += substr($i, 19) + 0
        else if ($i ~ /^base_ref_ms=/) base += substr($i, 13) + 0
        else if ($i ~ /^ahead_behind_ms=/) ahead += substr($i, 17) + 0
        else if ($i ~ /^merge_conflicts_ms=/) conflicts += substr($i, 20) + 0
        else if ($i ~ /^total_ms=/) total += substr($i, 10) + 0
      }
    }
    END {
      printf "%s %s %s %s %s %s %s %s %s", count + 0, repo + 0, tracked + 0, latest + 0, modified + 0, base + 0, ahead + 0, conflicts + 0, total + 0
    }
  ' "${PROFILE_LOG}"
}

extract_passed_metric() {
  local line="$1"
  sed -E 's/.*passed=([01]).*/\1/' <<<"${line}"
}

collect_setup_check_sample() {
  local check_lines=()
  local check_id
  for check_id in "${SETUP_CHECK_IDS[@]}"; do
    check_lines+=("$(find_pattern_anywhere "spaces: setup_check id=${check_id} elapsed_ms=[0-9]+ passed=[01]" || true)")
  done
  local startup_blocking_line
  local run_all_line
  startup_blocking_line="$(find_pattern_anywhere "spaces: setup_check stage=startup_blocking elapsed_ms=" || true)"
  run_all_line="$(find_pattern_anywhere "spaces: setup_check stage=run_all elapsed_ms=" || true)"

  for line in "${check_lines[@]}"; do
    if [[ -n "${line}" ]]; then
      printf '%s %s ' "$(extract_metric "${line}" "elapsed_ms")" "$(extract_passed_metric "${line}")"
    else
      printf '%s %s ' "-1" "-1"
    fi
  done
  if [[ -n "${startup_blocking_line}" ]]; then
    printf '%s' "$(extract_metric "${startup_blocking_line}" "elapsed_ms")"
  elif [[ -n "${run_all_line}" ]]; then
    printf '%s' "$(extract_metric "${run_all_line}" "elapsed_ms")"
  else
    printf '%s' "-1"
  fi
}

summarize_setup_check_samples() {
  local samples_file="$1"
  awk '
    function fmt(label, avg, pass_ratio) {
      if (avg < 0) {
        printf "%-24s deferred\n", label
      } else if (pass_ratio == "") {
        printf "%-24s avg=%6.1fms\n", label, avg
      } else {
        printf "%-24s avg=%6.1fms  passed=%4.1f%%\n", label, avg, pass_ratio
      }
    }
    {
      iterm += $1; iterm_pass += $2
      tmux += $3; tmux_pass += $4
      yabai += $5; yabai_pass += $6
      spaces += $7; spaces_pass += $8
      windows += $9; windows_pass += $10
      total += $11
      count += 1
    }
    END {
      if (count == 0) exit 0
      fmt("iterm2Installed", iterm / count, (iterm_pass / count) * 100)
      fmt("tmuxInstalled", tmux / count, (tmux_pass / count) * 100)
      fmt("yabaiInstalled", yabai / count, (yabai_pass / count) * 100)
      fmt("yabaiServiceRunning", spaces / count, (spaces_pass / count) * 100)
      fmt("yabaiAccessibility", windows / count, (windows_pass / count) * 100)
      print ""
      fmt("setup_startup_blocking", total / count, "")
    }
  ' "${samples_file}"
}

main() {
  require_file "${SPACES_APP}"
  require_file "${MX_BIN}"
  build_if_needed
  ensure_workspace_exists

  local startup_samples
  startup_samples="$(mktemp)"

  if [[ "${STARTUP_SAMPLE_COUNT}" -gt 0 ]]; then
    for _ in $(seq 1 "${STARTUP_SAMPLE_COUNT}"); do
      collect_startup_sample >>"${startup_samples}"
    done
  fi

  local spaces_to_browser_samples=""
  local spaces_to_iterm_samples=""
  local browser_to_browser_samples=""
  local browser_to_iterm_samples=""
  local iterm_to_iterm_samples=""
  local iterm_to_browser_samples=""

  if [[ "${SAMPLE_COUNT}" -gt 0 ]]; then
    if [[ "${RELAUNCH_DEBUG_APP}" == "1" ]]; then
      close_existing_spaces_instances
      launch_debug_spaces
    else
      focus_spaces_app
      : > "${PROFILE_LOG}"
    fi

    spaces_to_browser_samples="$(mktemp)"
    spaces_to_iterm_samples="$(mktemp)"
    browser_to_browser_samples="$(mktemp)"
    browser_to_iterm_samples="$(mktemp)"
    iterm_to_iterm_samples="$(mktemp)"
    iterm_to_browser_samples="$(mktemp)"

    for _ in $(seq 1 "${SAMPLE_COUNT}"); do collect_direct_shortcut_sample "${SPACES_TO_BROWSER_INDEX}" >>"${spaces_to_browser_samples}"; done
    for _ in $(seq 1 "${SAMPLE_COUNT}"); do collect_direct_shortcut_sample "${SPACES_TO_ITERM_INDEX}" >>"${spaces_to_iterm_samples}"; done
    for _ in $(seq 1 "${SAMPLE_COUNT}"); do collect_cycle_sample "${BROWSER_TO_BROWSER_START_INDEX}" >>"${browser_to_browser_samples}"; done
    for _ in $(seq 1 "${SAMPLE_COUNT}"); do collect_cycle_sample "${BROWSER_TO_ITERM_START_INDEX}" >>"${browser_to_iterm_samples}"; done
    for _ in $(seq 1 "${SAMPLE_COUNT}"); do collect_cycle_sample "${ITERM_TO_ITERM_START_INDEX}" >>"${iterm_to_iterm_samples}"; done
    for _ in $(seq 1 "${SAMPLE_COUNT}"); do collect_cycle_sample "${ITERM_TO_BROWSER_START_INDEX}" >>"${iterm_to_browser_samples}"; done
  fi

  echo
  echo "Startup profile summary"
  echo "startup samples: ${STARTUP_SAMPLE_COUNT}"
  echo "startup shortcut index: ${STARTUP_SHORTCUT_INDEX}"
  echo "log file: ${PROFILE_LOG}"
  echo
  summarize_startup_samples "${startup_samples}"
  echo
  echo "Setup check profile summary"
  echo
  summarize_setup_check_samples "${startup_samples}"
  echo
  if [[ "${SAMPLE_COUNT}" -gt 0 ]]; then
    echo "Window focus profile summary"
    echo "workspace: ${WORKSPACE_DIR}"
    echo "samples per action: ${SAMPLE_COUNT}"
    echo "log file: ${PROFILE_LOG}"
    echo
    summarize_samples "spaces_to_browser" "${spaces_to_browser_samples}"
    summarize_samples "spaces_to_iterm" "${spaces_to_iterm_samples}"
    summarize_samples "browser_to_browser" "${browser_to_browser_samples}"
    summarize_samples "browser_to_iterm" "${browser_to_iterm_samples}"
    summarize_samples "iterm_to_iterm" "${iterm_to_iterm_samples}"
    summarize_samples "iterm_to_browser" "${iterm_to_browser_samples}"
  fi
}

main "$@"
