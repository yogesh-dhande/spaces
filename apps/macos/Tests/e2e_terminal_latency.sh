#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
source "$SCRIPT_DIR/terminal_harness_lock.sh"
source "$REPO_ROOT/scripts/spaces-profile-helpers.sh"

BUILD_DIR="$APP_ROOT/.build/debug"
SPACES_APP="${SPACES_APP:-$BUILD_DIR/SpacesApp}"
SPACES_CLI="${SPACES_CLI:-$BUILD_DIR/spaces}"
SPACES_E2E="${SPACES_E2E:-$BUILD_DIR/spacese2e}"
SETUP_GHOSTTYKIT="$APP_ROOT/scripts/setup_ghosttykit.sh"

WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-terminal-latency.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/runtime}"
APP_LOG="$WORK_ROOT/spaces-app.log"
PERF_JSONL="$WORK_ROOT/terminal-performance.jsonl"
SUMMARY_JSON="$WORK_ROOT/terminal-latency-summary.json"
SAMPLES="${SAMPLES:-12}"
KEEP_ROOT="${KEEP_ROOT:-0}"
APP_PID=""

SCENARIOS=(mac-input-latency mac-scrollback-latency mac-command-output-catchup)
SELECTED_SCENARIOS=()

print_usage() {
  cat <<'EOF'
Usage: apps/macos/Tests/e2e_terminal_latency.sh [options]

Options:
  --list             List available scenarios.
  --scenario NAME    Run only one scenario. May be passed multiple times.
  --samples N        Probe count per scenario. Defaults to 12.
  --keep-root        Preserve the temporary profile root.
  --help             Show this help text.

Scenarios:
  mac-input-latency
  mac-scrollback-latency
  mac-command-output-catchup
EOF
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  KEEP_ROOT=1
  if [[ -f "$APP_LOG" ]]; then
    printf '\nMac app log tail:\n' >&2
    tail -n 160 "$APP_LOG" >&2 || true
  fi
  exit 1
}

scenario_exists() {
  local requested="$1"
  local scenario
  for scenario in "${SCENARIOS[@]}"; do
    [[ "$scenario" == "$requested" ]] && return 0
  done
  return 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --list)
        printf '%s\n' "${SCENARIOS[@]}"
        exit 0
        ;;
      --scenario)
        [[ $# -ge 2 ]] || fail "missing value for --scenario"
        scenario_exists "$2" || fail "unknown scenario: $2"
        SELECTED_SCENARIOS+=("$2")
        shift 2
        ;;
      --samples)
        [[ $# -ge 2 ]] || fail "missing value for --samples"
        SAMPLES="$2"
        shift 2
        ;;
      --keep-root)
        KEEP_ROOT=1
        shift
        ;;
      --help)
        print_usage
        exit 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
  done
  if [[ ${#SELECTED_SCENARIOS[@]} -eq 0 ]]; then
    SELECTED_SCENARIOS=("${SCENARIOS[@]}")
  fi
}

cleanup() {
  local exit_code=$?
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
  stop_terminal_service_for_runtime_dir "$RUNTIME_DIR" 5
  release_terminal_harness_lock
  if [[ "$KEEP_ROOT" == "1" || $exit_code -ne 0 ]]; then
    printf 'Preserved latency root: %s\n' "$WORK_ROOT" >&2
  else
    rm -rf "$WORK_ROOT" || true
  fi
  return "$exit_code"
}
trap cleanup EXIT

parse_args "$@"
[[ "$SAMPLES" =~ ^[0-9]+$ && "$SAMPLES" -gt 0 ]] || fail "--samples must be a positive integer"
[[ -x "$SPACES_APP" ]] || fail "SpacesApp not found at $SPACES_APP"
[[ -x "$SPACES_CLI" ]] || fail "spaces CLI not found at $SPACES_CLI"
[[ -x "$SPACES_E2E" ]] || fail "spacese2e not found at $SPACES_E2E"

mkdir -p "$(dirname "$DB_PATH")" "$RUNTIME_DIR"
touch "$APP_LOG" "$PERF_JSONL"
export SPACES_DB_PATH="$DB_PATH"
export SPACES_RUNTIME_DIR="$RUNTIME_DIR"

cd "$REPO_ROOT"
acquire_terminal_harness_lock
"$SETUP_GHOSTTYKIT"
spaces_profile_stop_running_app "$SPACES_CLI"

env \
  SPACES_DB_PATH="$DB_PATH" \
  SPACES_RUNTIME_DIR="$RUNTIME_DIR" \
  SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH="$PERF_JSONL" \
  DEBUG=1 \
  "$SPACES_APP" >"$APP_LOG" 2>&1 &
APP_PID="$!"
spaces_profile_wait_for_owner_pid "$SPACES_CLI" "$APP_PID" 20
sleep 1

python3 - "$SPACES_CLI" "$SPACES_E2E" "$RUNTIME_DIR" "$WORK_ROOT" "$PERF_JSONL" "$SUMMARY_JSON" "$SAMPLES" "${SELECTED_SCENARIOS[@]}" <<'PY'
import json
import math
import os
import re
import sqlite3
import statistics
import subprocess
import sys
import time
import uuid
from pathlib import Path

spaces_cli, spacese2e, runtime_dir, work_root, performance_log_path, summary_json, sample_count, *scenarios = sys.argv[1:]
sample_count = int(sample_count)
runtime_dir = Path(runtime_dir)
work_root = Path(work_root)
performance_log_path = Path(performance_log_path)
summary_json = Path(summary_json)
app_executable_name = "SpacesApp"
base_env = os.environ.copy()

events: list[dict] = []
scenario_results: dict[str, dict] = {}

budgets = {
    "mac-input-latency": {"gross_p95_ms": 500, "target_p95_ms": 75},
    "mac-scrollback-latency": {"gross_p95_ms": 500, "target_p95_ms": 75},
    "mac-command-output-catchup": {"gross_p95_ms": 2000, "target_p95_ms": 150},
}


def now_ns() -> int:
    return time.monotonic_ns()


def ms_between(start_ns: int, end_ns: int) -> float:
    return round((end_ns - start_ns) / 1_000_000, 3)


def event(name: str, scenario: str, probe_id: str, at_ns: int | None = None, **attributes: object) -> None:
    events.append(
        {
            "name": name,
            "scenario": scenario,
            "probe_id": probe_id,
            "monotonic_ns": at_ns if at_ns is not None else now_ns(),
            "attributes": attributes,
        }
    )


def run(command: list[str], timeout: float = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, env=base_env, capture_output=True, text=True, timeout=timeout, check=True)


def read_performance_events() -> list[dict]:
    if not performance_log_path.exists():
        return []
    records = []
    for line in performance_log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return records


def performance_event_uptime(record: dict) -> int | None:
    try:
        return int(record["emittedUptimeNanoseconds"])
    except (KeyError, TypeError, ValueError):
        return None


def performance_event(
    session_id: str,
    source: str,
    name: str,
    after_ns: int,
    before_ns: int | None = None,
    timeout: float = 1.0,
    require_render_frame: bool = True,
    attribute_equals: dict[str, str] | None = None,
    latest: bool = True,
) -> tuple[dict, int] | None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        candidates = []
        for record in read_performance_events():
            if record.get("sessionID") != session_id or record.get("source") != source or record.get("name") != name:
                continue
            emitted_ns = performance_event_uptime(record)
            if emitted_ns is None or emitted_ns < after_ns:
                continue
            if before_ns is not None and emitted_ns > before_ns:
                continue
            attributes = record.get("attributes") or {}
            if require_render_frame:
                if attributes.get("render_frame") != "1" or attributes.get("drop_reason") not in (None, "none"):
                    continue
            if attribute_equals and any(attributes.get(key) != value for key, value in attribute_equals.items()):
                continue
            candidates.append((emitted_ns, record))
        if candidates:
            emitted_ns, record = (max if latest else min)(candidates, key=lambda item: item[0])
            return record, emitted_ns
        time.sleep(0.02)
    return None


def last_performance_event(
    session_id: str,
    source: str,
    name: str,
    after_ns: int,
    before_ns: int | None = None,
    timeout: float = 1.0,
    require_render_frame: bool = True,
    attribute_equals: dict[str, str] | None = None,
) -> tuple[dict, int] | None:
    return performance_event(
        session_id,
        source,
        name,
        after_ns,
        before_ns=before_ns,
        timeout=timeout,
        require_render_frame=require_render_frame,
        attribute_equals=attribute_equals,
        latest=True,
    )


def first_performance_event(
    session_id: str,
    source: str,
    name: str,
    after_ns: int,
    before_ns: int | None = None,
    timeout: float = 1.0,
    require_render_frame: bool = True,
    attribute_equals: dict[str, str] | None = None,
) -> tuple[dict, int] | None:
    return performance_event(
        session_id,
        source,
        name,
        after_ns,
        before_ns=before_ns,
        timeout=timeout,
        require_render_frame=require_render_frame,
        attribute_equals=attribute_equals,
        latest=False,
    )


def target_revision_for_mac_apply(session_id: str, begin_ns: int, visible_ns: int) -> tuple[str | None, int | None]:
    frame_export = last_performance_event(session_id, "mac-host", "render_frame_export_end", begin_ns, before_ns=visible_ns)
    if not frame_export:
        return None, None
    target_revision = (frame_export[0].get("attributes") or {}).get("target_revision")
    return (target_revision if target_revision and target_revision != "nil" else None), frame_export[1]


def first_mac_frame_apply(session_id: str, begin_ns: int, visible_ns: int) -> tuple[dict, int] | None:
    target_revision, frame_export_ns = target_revision_for_mac_apply(session_id, begin_ns, visible_ns)
    attribute_filter = {"applied_revision": target_revision} if target_revision else None
    return first_performance_event(
        session_id,
        "mac-mirror",
        "render_frame_mirror_apply",
        frame_export_ns if frame_export_ns is not None else begin_ns,
        before_ns=visible_ns,
        attribute_equals=attribute_filter,
    )


def extract_session_id(output: str) -> str:
    match = re.findall(r"[0-9A-Fa-f-]{36}", output)
    if not match:
        raise RuntimeError(f"failed to parse session id from: {output}")
    return match[-1].upper()


def wait_for_session_id_by_title(title: str, timeout: float = 10) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with sqlite3.connect(os.environ["SPACES_DB_PATH"]) as db:
            rows = db.execute(
                "SELECT session_id, root_directory FROM terminal_sessions WHERE title = ? ORDER BY created_at DESC",
                (title,),
            ).fetchall()
        for session_id, root_directory in rows:
            if (Path(root_directory) / "control.sock").exists():
                return session_id.upper()
        time.sleep(0.1)
    raise TimeoutError(f"timed out recovering session id for title {title}")


def request_terminal_window(session_id: str) -> None:
    run([spaces_cli, "terminal", "show", session_id], timeout=5)
    time.sleep(0.5)


def start_terminal(title: str, command: str | None) -> str:
    try:
        arguments = [
            spaces_cli,
            "terminal",
            "command",
            "--backend",
            "ghostty-embedded",
            "--title",
            title,
        ]
        if command is not None:
            arguments.extend(["--command", command])
        completed = run(
            arguments,
            timeout=20,
        )
        session_id = extract_session_id(completed.stdout)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        try:
            session_id = wait_for_session_id_by_title(title)
        except TimeoutError:
            stdout = getattr(error, "stdout", None) or getattr(error, "output", None) or ""
            stderr = getattr(error, "stderr", None) or ""
            raise RuntimeError(f"failed to start terminal title={title!r}\nstdout:\n{stdout}\nstderr:\n{stderr}") from error
    request_terminal_window(session_id)
    return session_id


def dump_state(session_id: str, suffix: str) -> dict:
    output_path = work_root / f"{session_id}-{suffix}-{uuid.uuid4().hex}.json"
    run(
        [
            spacese2e,
            "dump-terminal-session-window-state",
            "--session-id",
            session_id,
            "--output-path",
            str(output_path),
        ],
        timeout=5,
    )
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if output_path.exists():
            try:
                return json.loads(output_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                pass
        time.sleep(0.02)
    raise TimeoutError(f"timed out waiting for state dump for {session_id}")


def wait_for_state(session_id: str, predicate, timeout: float, suffix: str) -> tuple[dict, int]:
    deadline = time.monotonic() + timeout
    last_state = None
    while time.monotonic() < deadline:
        state = dump_state(session_id, suffix)
        last_state = state
        if predicate(state):
            return state, now_ns()
        time.sleep(0.02)
    raise TimeoutError(f"timed out waiting for terminal state; last={last_state}")


def rendered_output(state: dict) -> str:
    return state.get("renderedOutput") or ""


def compact_rendered_output(state: dict) -> str:
    return "".join(rendered_output(state).split())


def renderer_is_ghostty(state: dict) -> bool:
    summary = state.get("rendererSummary") or ""
    return "ghostty-mirror" in summary


def percentile(values: list[float], pct: float) -> float:
    ordered = sorted(values)
    index = max(math.ceil(len(ordered) * pct) - 1, 0)
    return ordered[index]


def summarize_values(values: list[float]) -> dict:
    if not values:
        return {
            "count": 0,
            "p50_ms": None,
            "p95_ms": None,
            "max_ms": None,
        }
    return {
        "count": len(values),
        "p50_ms": round(statistics.median(values), 3),
        "p95_ms": round(percentile(values, 0.95), 3),
        "max_ms": round(max(values), 3),
    }


def summarize_latencies(measurements: list[dict], key: str = "event_to_visible_ms") -> dict:
    return summarize_values([float(item[key]) for item in measurements if item.get(key) is not None])


def summarize_phases(measurements: list[dict]) -> dict:
    return {
        "enqueue_to_rpc_begin": summarize_latencies(measurements, "enqueue_to_rpc_begin_ms"),
        "rpc_duration": summarize_latencies(measurements, "rpc_ms"),
        "owner_input_activity_to_state_change": summarize_latencies(measurements, "owner_input_activity_to_state_change_ms"),
        "state_change_to_frame_export": summarize_latencies(measurements, "state_change_to_frame_export_ms"),
        "frame_export_to_frame_apply": summarize_latencies(measurements, "frame_export_to_frame_apply_ms"),
        "event_to_frame_apply": summarize_latencies(measurements, "event_to_frame_apply_ms"),
        "frame_apply_to_visible": summarize_latencies(measurements, "frame_apply_to_visible_ms"),
        "rpc_end_to_render_visible": summarize_latencies(measurements, "rpc_end_to_render_visible_ms"),
        "event_to_visible_total": summarize_latencies(measurements, "event_to_visible_ms"),
    }


def mac_host_latency_split(session_id: str, begin_ns: int, frame_apply_ns: int | None, visible_ns: int) -> dict:
    before_ns = frame_apply_ns if frame_apply_ns is not None else visible_ns
    owner_activity = last_performance_event(
        session_id, "mac-host", "owner_input_activity", begin_ns, before_ns=before_ns, require_render_frame=False
    )
    owner_activity_ns = owner_activity[1] if owner_activity else None
    state_change = last_performance_event(
        session_id,
        "mac-host",
        "state_change",
        owner_activity_ns if owner_activity_ns is not None else begin_ns,
        before_ns=before_ns,
        require_render_frame=False,
    )
    state_change_ns = state_change[1] if state_change else None
    frame_export = last_performance_event(
        session_id,
        "mac-host",
        "render_frame_export_end",
        state_change_ns if state_change_ns is not None else begin_ns,
        before_ns=before_ns,
    )
    frame_export_ns = frame_export[1] if frame_export else None
    return {
        "owner_input_activity_to_state_change_ms": (
            ms_between(owner_activity_ns, state_change_ns) if owner_activity_ns is not None and state_change_ns is not None else None
        ),
        "state_change_to_frame_export_ms": (
            ms_between(state_change_ns, frame_export_ns) if state_change_ns is not None and frame_export_ns is not None else None
        ),
        "frame_export_to_frame_apply_ms": (
            ms_between(frame_export_ns, frame_apply_ns) if frame_export_ns is not None and frame_apply_ns is not None else None
        ),
    }


def format_ms(value: float | None) -> str:
    return "n/a" if value is None else f"{value}ms"


def sample_series(measurements: list[dict], key: str = "event_to_visible_ms", limit: int = 12) -> str:
    samples = []
    for fallback_index, measurement in enumerate(measurements[:limit], start=1):
        sample_index = measurement.get("sample_index") or fallback_index
        samples.append(f"#{sample_index}={format_ms(measurement.get(key))}")
    if len(measurements) > limit:
        samples.append(f"... {len(measurements) - limit} more")
    return ", ".join(samples)


def run_mac_input_latency() -> dict:
    scenario = "mac-input-latency"
    title = f"{scenario}-{uuid.uuid4().hex[:8]}"
    session_id = start_terminal(title, "cat")
    initial_state, _ = wait_for_state(session_id, lambda state: state.get("found") and renderer_is_ghostty(state), 20, "initial")
    measurements = []
    input_alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
    expected_text = ""
    for index in range(sample_count):
        probe_id = f"mac-input-{index + 1:03d}-{uuid.uuid4().hex[:8]}"
        input_text = input_alphabet[index % len(input_alphabet)]
        expected_text += input_text
        enqueue_ns = now_ns()
        event("mac_input_enqueue", scenario, probe_id, enqueue_ns)
        rpc_begin_ns = now_ns()
        event("mac_input_rpc_begin", scenario, probe_id, rpc_begin_ns, enqueue_to_rpc_begin_ms=ms_between(enqueue_ns, rpc_begin_ns))
        try:
            completed = run(
                [
                    spacese2e,
                    "type-application-window",
                    "--executable-name",
                    app_executable_name,
                    "--window-title-contains",
                    title,
                    "--normalized-y",
                    "0.58",
                    "--text",
                    input_text,
                    "--inter-key-delay-ms",
                    "0",
                ],
                timeout=10,
            )
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            stdout = getattr(error, "stdout", None) or getattr(error, "output", None) or ""
            stderr = getattr(error, "stderr", None) or ""
            raise RuntimeError(
                "real application-window typing failed; mac-input-latency requires Accessibility automation for spacese2e\n"
                f"stdout:\n{stdout}\nstderr:\n{stderr}"
            ) from error
        rpc_end_ns = now_ns()
        try:
            helper_payload = json.loads(completed.stdout)
            begin_ns = int(helper_payload["firstKeyDownUptimeNanoseconds"])
            key_up_ns = int(helper_payload["lastKeyUpUptimeNanoseconds"])
        except (json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
            raise RuntimeError(f"failed to parse spacese2e keyboard timing payload: {completed.stdout}") from error
        event("mac_input_begin", scenario, probe_id, begin_ns, input_text=input_text)
        event(
            "mac_input_rpc_end",
            scenario,
            probe_id,
            rpc_end_ns,
            rpc_ms=ms_between(rpc_begin_ns, rpc_end_ns),
            rpc_begin_to_key_event_ms=ms_between(rpc_begin_ns, begin_ns),
            key_up_to_rpc_end_ms=ms_between(key_up_ns, rpc_end_ns),
        )
        visible_state, visible_ns = wait_for_state(
            session_id, lambda state, expected_text=expected_text: expected_text in compact_rendered_output(state), 5, probe_id)
        frame_apply = first_mac_frame_apply(session_id, begin_ns, visible_ns)
        frame_apply_ns = frame_apply[1] if frame_apply else None
        event_to_frame_apply_ms = ms_between(begin_ns, frame_apply_ns) if frame_apply_ns is not None else None
        frame_apply_to_visible_ms = ms_between(frame_apply_ns, visible_ns) if frame_apply_ns is not None else None
        stage_split = mac_host_latency_split(session_id, begin_ns, frame_apply_ns, visible_ns)
        if frame_apply_ns is not None:
            event(
                "mac_input_frame_applied",
                scenario,
                probe_id,
                frame_apply_ns,
                event_to_frame_apply_ms=event_to_frame_apply_ms,
                frame_apply_to_visible_ms=frame_apply_to_visible_ms,
                target_revision=(frame_apply[0].get("attributes") or {}).get("target_revision"),
                applied_revision=(frame_apply[0].get("attributes") or {}).get("applied_revision"),
            )
        event(
            "mac_input_echo_visible",
            scenario,
            probe_id,
            visible_ns,
            rpc_end_to_render_visible_ms=ms_between(rpc_end_ns, visible_ns),
            event_to_visible_ms=ms_between(begin_ns, visible_ns),
        )
        measurements.append(
            {
                "sample_index": index + 1,
                "probe_id": probe_id,
                "input_text": input_text,
                "enqueue_to_rpc_begin_ms": ms_between(enqueue_ns, rpc_begin_ns),
                "rpc_end_to_render_visible_ms": ms_between(rpc_end_ns, visible_ns),
                "owner_input_activity_to_state_change_ms": stage_split["owner_input_activity_to_state_change_ms"],
                "state_change_to_frame_export_ms": stage_split["state_change_to_frame_export_ms"],
                "frame_export_to_frame_apply_ms": stage_split["frame_export_to_frame_apply_ms"],
                "event_to_frame_apply_ms": event_to_frame_apply_ms,
                "frame_apply_to_visible_ms": frame_apply_to_visible_ms,
                "event_to_visible_ms": ms_between(begin_ns, visible_ns),
                "visible_latency_ms": ms_between(begin_ns, visible_ns),
                "rpc_ms": ms_between(rpc_begin_ns, rpc_end_ns),
                "rpc_begin_to_key_event_ms": ms_between(rpc_begin_ns, begin_ns),
                "key_up_to_rpc_end_ms": ms_between(key_up_ns, rpc_end_ns),
                "render_mode": "ghostty-mirror" if renderer_is_ghostty(visible_state) else visible_state.get("rendererSummary"),
            }
        )
    return {
        "session_id": session_id,
        "window_title": title,
        "initial_render_mode": initial_state.get("rendererSummary"),
        "measurements": measurements,
        "summary": summarize_latencies(measurements),
        "phase_summaries": summarize_phases(measurements),
        "budget_enforced": True,
    }


def run_mac_scrollback_latency() -> dict:
    scenario = "mac-scrollback-latency"
    title = f"{scenario}-{uuid.uuid4().hex[:8]}"
    command = (
        "/usr/bin/python3 -c 'import sys,time\n"
        "for i in range(1600): print(f\"SCROLLLINE {i:04d}\", flush=True)\n"
        "print(\"SCROLL_READY\", flush=True)\n"
        "time.sleep(300)'"
    )
    session_id = start_terminal(title, command)
    initial_state, _ = wait_for_state(
        session_id,
        lambda state: state.get("found") and renderer_is_ghostty(state) and "SCROLL_READY" in rendered_output(state),
        30,
        "scroll-ready",
    )
    measurements = []
    base_delta_y = int(os.environ.get("MAC_SCROLL_DELTA_Y", "720"))
    for index in range(sample_count):
        probe_id = f"mac-scroll-{index + 1:03d}-{uuid.uuid4().hex[:8]}"
        delta_y = base_delta_y if index % 2 == 0 else -base_delta_y
        before = rendered_output(dump_state(session_id, f"{probe_id}-before"))
        enqueue_ns = now_ns()
        event("mac_scroll_enqueue", scenario, probe_id, enqueue_ns, delta_y=delta_y)
        rpc_begin_ns = now_ns()
        event("mac_scroll_rpc_begin", scenario, probe_id, rpc_begin_ns, enqueue_to_rpc_begin_ms=ms_between(enqueue_ns, rpc_begin_ns))
        completed = run(
            [
                spacese2e,
                "scroll-application-window",
                "--executable-name",
                app_executable_name,
                "--window-title-contains",
                title,
                "--normalized-y",
                "0.58",
                f"--delta-y={delta_y}",
                "--repetitions",
                "1",
            ],
            timeout=10,
        )
        rpc_end_ns = now_ns()
        try:
            helper_payload = json.loads(completed.stdout)
            begin_ns = int(helper_payload["firstScrollEventUptimeNanoseconds"])
            scroll_end_ns = int(helper_payload["lastScrollEventUptimeNanoseconds"])
        except (json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
            raise RuntimeError(f"failed to parse spacese2e scroll timing payload: {completed.stdout}") from error
        event("mac_scroll_begin", scenario, probe_id, begin_ns, delta_y=delta_y)
        event(
            "mac_scroll_rpc_end",
            scenario,
            probe_id,
            rpc_end_ns,
            rpc_ms=ms_between(rpc_begin_ns, rpc_end_ns),
            rpc_begin_to_scroll_event_ms=ms_between(rpc_begin_ns, begin_ns),
            scroll_end_to_rpc_end_ms=ms_between(scroll_end_ns, rpc_end_ns),
        )
        visible_state = None
        visible_ns = None
        rendered_change_latency_ms = None
        rpc_end_to_render_visible_ms = None
        event_to_frame_apply_ms = None
        frame_apply_to_visible_ms = None
        no_op = False
        try:
            visible_state, visible_ns = wait_for_state(session_id, lambda state, before=before: rendered_output(state) != before, 5, probe_id)
            rendered_change_latency_ms = ms_between(begin_ns, visible_ns)
            rpc_end_to_render_visible_ms = ms_between(rpc_end_ns, visible_ns)
            frame_apply = first_mac_frame_apply(session_id, begin_ns, visible_ns)
            frame_apply_ns = frame_apply[1] if frame_apply else None
            event_to_frame_apply_ms = ms_between(begin_ns, frame_apply_ns) if frame_apply_ns is not None else None
            frame_apply_to_visible_ms = ms_between(frame_apply_ns, visible_ns) if frame_apply_ns is not None else None
            stage_split = mac_host_latency_split(session_id, begin_ns, frame_apply_ns, visible_ns)
            if frame_apply_ns is not None:
                event(
                    "mac_scroll_frame_applied",
                    scenario,
                    probe_id,
                    frame_apply_ns,
                    event_to_frame_apply_ms=event_to_frame_apply_ms,
                    frame_apply_to_visible_ms=frame_apply_to_visible_ms,
                    target_revision=(frame_apply[0].get("attributes") or {}).get("target_revision"),
                    applied_revision=(frame_apply[0].get("attributes") or {}).get("applied_revision"),
                )
            event(
                "mac_scroll_rendered_change",
                scenario,
                probe_id,
                visible_ns,
                rpc_end_to_render_visible_ms=rpc_end_to_render_visible_ms,
                event_to_visible_ms=rendered_change_latency_ms,
            )
        except TimeoutError:
            no_op = True
            visible_state = dump_state(session_id, f"{probe_id}-noop")
            stage_split = {
                "owner_input_activity_to_state_change_ms": None,
                "state_change_to_frame_export_ms": None,
                "frame_export_to_frame_apply_ms": None,
            }
            event("mac_scroll_noop", scenario, probe_id, now_ns(), delta_y=delta_y)
        measurements.append(
            {
                "sample_index": index + 1,
                "probe_id": probe_id,
                "delta_y": delta_y,
                "enqueue_to_rpc_begin_ms": ms_between(enqueue_ns, rpc_begin_ns),
                "event_to_visible_ms": rendered_change_latency_ms,
                "visible_latency_ms": rendered_change_latency_ms,
                "rpc_end_to_render_visible_ms": rpc_end_to_render_visible_ms,
                "owner_input_activity_to_state_change_ms": stage_split["owner_input_activity_to_state_change_ms"],
                "state_change_to_frame_export_ms": stage_split["state_change_to_frame_export_ms"],
                "frame_export_to_frame_apply_ms": stage_split["frame_export_to_frame_apply_ms"],
                "event_to_frame_apply_ms": event_to_frame_apply_ms,
                "frame_apply_to_visible_ms": frame_apply_to_visible_ms,
                "rendered_change_latency_ms": rendered_change_latency_ms,
                "rpc_ms": ms_between(rpc_begin_ns, rpc_end_ns),
                "rpc_begin_to_scroll_event_ms": ms_between(rpc_begin_ns, begin_ns),
                "scroll_end_to_rpc_end_ms": ms_between(scroll_end_ns, rpc_end_ns),
                "no_op": no_op,
                "render_mode": "ghostty-mirror" if renderer_is_ghostty(visible_state) else visible_state.get("rendererSummary"),
            }
        )
    return {
        "session_id": session_id,
        "window_title": title,
        "initial_render_mode": initial_state.get("rendererSummary"),
        "measurements": measurements,
        "summary": summarize_latencies(measurements),
        "phase_summaries": summarize_phases(measurements),
        "no_op_gestures": sum(1 for item in measurements if item.get("no_op")),
        "rendered_change_count": sum(1 for item in measurements if not item.get("no_op")),
        "report_only": True,
        "budget_enforced": False,
    }


def run_mac_command_output_catchup() -> dict:
    scenario = "mac-command-output-catchup"
    title_prefix = f"{scenario}-{uuid.uuid4().hex[:8]}"
    initial_render_modes = []
    session_ids = []
    measurements = []
    for index in range(sample_count):
        title = f"{title_prefix}-{index + 1:03d}"
        session_id = start_terminal(title, None)
        session_ids.append(session_id)
        initial_state, _ = wait_for_state(session_id, lambda state: state.get("found") and renderer_is_ghostty(state), 20, "initial")
        initial_render_modes.append(initial_state.get("rendererSummary"))
        probe_id = f"mac-command-{index + 1:03d}-{uuid.uuid4().hex[:8]}"
        marker_prefix = f"__mac_command_probe_{index + 1:03d}_"
        marker_suffix = uuid.uuid4().hex[:10]
        marker = f"{marker_prefix}{marker_suffix}__"
        command_text = f"echo '{marker_prefix}'\"{marker_suffix}\"'__'"
        enqueue_ns = now_ns()
        event("mac_command_enqueue", scenario, probe_id, enqueue_ns)
        rpc_begin_ns = now_ns()
        event("mac_command_rpc_begin", scenario, probe_id, rpc_begin_ns, enqueue_to_rpc_begin_ms=ms_between(enqueue_ns, rpc_begin_ns))
        completed = run(
            [
                spacese2e,
                "type-application-window",
                "--executable-name",
                app_executable_name,
                "--window-title-contains",
                title,
                "--normalized-y",
                "0.58",
                "--text",
                command_text,
                "--append-newline",
                "--inter-key-delay-ms",
                "5",
            ],
            timeout=15,
        )
        rpc_end_ns = now_ns()
        try:
            helper_payload = json.loads(completed.stdout)
            begin_ns = int(helper_payload["firstKeyDownUptimeNanoseconds"])
            key_up_ns = int(helper_payload["lastKeyUpUptimeNanoseconds"])
        except (json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
            raise RuntimeError(f"failed to parse spacese2e keyboard timing payload: {completed.stdout}") from error
        event("mac_command_begin", scenario, probe_id, begin_ns, marker=marker)
        event(
            "mac_command_rpc_end",
            scenario,
            probe_id,
            rpc_end_ns,
            rpc_ms=ms_between(rpc_begin_ns, rpc_end_ns),
            rpc_begin_to_key_event_ms=ms_between(rpc_begin_ns, begin_ns),
            key_up_to_rpc_end_ms=ms_between(key_up_ns, rpc_end_ns),
        )
        visible_state, visible_ns = wait_for_state(
            session_id, lambda state, marker=marker: marker in compact_rendered_output(state), 8, probe_id)
        frame_apply = first_mac_frame_apply(session_id, begin_ns, visible_ns)
        frame_apply_ns = frame_apply[1] if frame_apply else None
        event_to_frame_apply_ms = ms_between(begin_ns, frame_apply_ns) if frame_apply_ns is not None else None
        frame_apply_to_visible_ms = ms_between(frame_apply_ns, visible_ns) if frame_apply_ns is not None else None
        stage_split = mac_host_latency_split(session_id, begin_ns, frame_apply_ns, visible_ns)
        if frame_apply_ns is not None:
            event(
                "mac_command_frame_applied",
                scenario,
                probe_id,
                frame_apply_ns,
                event_to_frame_apply_ms=event_to_frame_apply_ms,
                frame_apply_to_visible_ms=frame_apply_to_visible_ms,
                target_revision=(frame_apply[0].get("attributes") or {}).get("target_revision"),
                applied_revision=(frame_apply[0].get("attributes") or {}).get("applied_revision"),
            )
        event(
            "mac_command_output_visible",
            scenario,
            probe_id,
            visible_ns,
            rpc_end_to_render_visible_ms=ms_between(rpc_end_ns, visible_ns),
            event_to_visible_ms=ms_between(begin_ns, visible_ns),
        )
        measurements.append(
            {
                "sample_index": index + 1,
                "probe_id": probe_id,
                "session_id": session_id,
                "marker": marker,
                "enqueue_to_rpc_begin_ms": ms_between(enqueue_ns, rpc_begin_ns),
                "rpc_end_to_render_visible_ms": ms_between(rpc_end_ns, visible_ns),
                "owner_input_activity_to_state_change_ms": stage_split["owner_input_activity_to_state_change_ms"],
                "state_change_to_frame_export_ms": stage_split["state_change_to_frame_export_ms"],
                "frame_export_to_frame_apply_ms": stage_split["frame_export_to_frame_apply_ms"],
                "event_to_frame_apply_ms": event_to_frame_apply_ms,
                "frame_apply_to_visible_ms": frame_apply_to_visible_ms,
                "event_to_visible_ms": ms_between(begin_ns, visible_ns),
                "visible_latency_ms": ms_between(begin_ns, visible_ns),
                "rpc_ms": ms_between(rpc_begin_ns, rpc_end_ns),
                "rpc_begin_to_key_event_ms": ms_between(rpc_begin_ns, begin_ns),
                "key_up_to_rpc_end_ms": ms_between(key_up_ns, rpc_end_ns),
                "render_mode": "ghostty-mirror" if renderer_is_ghostty(visible_state) else visible_state.get("rendererSummary"),
            }
        )
    return {
        "session_ids": session_ids,
        "window_title": title_prefix,
        "initial_render_mode": initial_render_modes[0] if initial_render_modes else None,
        "measurements": measurements,
        "summary": summarize_latencies(measurements),
        "phase_summaries": summarize_phases(measurements),
        "budget_enforced": True,
    }


for scenario in scenarios:
    if scenario == "mac-input-latency":
        scenario_results[scenario] = run_mac_input_latency()
    elif scenario == "mac-scrollback-latency":
        scenario_results[scenario] = run_mac_scrollback_latency()
    elif scenario == "mac-command-output-catchup":
        scenario_results[scenario] = run_mac_command_output_catchup()
    else:
        raise RuntimeError(f"unknown scenario: {scenario}")

failures = []
for name, result in scenario_results.items():
    p95 = result["summary"]["p95_ms"]
    if result.get("budget_enforced", True) and p95 is not None and p95 > budgets[name]["gross_p95_ms"]:
        failures.append(f"{name} p95 {p95}ms exceeded gross budget {budgets[name]['gross_p95_ms']}ms")
    if any(item.get("render_mode") != "ghostty-mirror" for item in result["measurements"]):
        failures.append(f"{name} did not remain in ghostty-mirror render mode")

payload = {
    "suite": "terminal-latency",
    "scenarios": scenario_results,
    "events": events,
    "budgets": budgets,
    "failures": failures,
}
summary_json.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")

print(f"terminal latency summary: {summary_json}")
for name, result in scenario_results.items():
    summary = result["summary"]
    target = budgets[name]["target_p95_ms"]
    enforcement_text = "gross" if result.get("budget_enforced", True) else "report-only"
    print(
        f"{name}: p50={summary['p50_ms']}ms p95={summary['p95_ms']}ms max={summary['max_ms']}ms "
        f"(target p95 {target}ms, {enforcement_text} {budgets[name]['gross_p95_ms']}ms)"
    )
    phases = result.get("phase_summaries") or {}
    if phases:
        print(
            "  phases: "
            f"enqueue_to_rpc_begin p95={format_ms(phases['enqueue_to_rpc_begin']['p95_ms'])}, "
            f"rpc p95={format_ms(phases['rpc_duration']['p95_ms'])}, "
            f"owner_input_to_state_change p95={format_ms(phases['owner_input_activity_to_state_change']['p95_ms'])}, "
            f"state_change_to_frame_export p95={format_ms(phases['state_change_to_frame_export']['p95_ms'])}, "
            f"frame_export_to_apply p95={format_ms(phases['frame_export_to_frame_apply']['p95_ms'])}, "
            f"event_to_frame_apply p95={format_ms(phases['event_to_frame_apply']['p95_ms'])}, "
            f"frame_apply_to_visible p95={format_ms(phases['frame_apply_to_visible']['p95_ms'])}, "
            f"rpc_end_to_visible p95={format_ms(phases['rpc_end_to_render_visible']['p95_ms'])}, "
            f"event_to_visible p95={format_ms(phases['event_to_visible_total']['p95_ms'])}"
        )
    if result.get("measurements"):
        print(f"  samples: {sample_series(result['measurements'])}")
    if "no_op_gestures" in result:
        print(f"  scroll movement: rendered_changes={result['rendered_change_count']} no_ops={result['no_op_gestures']}")
if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    raise SystemExit(1)
PY
