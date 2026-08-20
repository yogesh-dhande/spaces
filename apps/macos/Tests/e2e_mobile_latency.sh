#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
source "$REPO_ROOT/scripts/spaces-e2e-env.sh"
spaces_e2e_load_env "$REPO_ROOT"
source "$SCRIPT_DIR/terminal_harness_lock.sh"
source "$SCRIPT_DIR/e2e_fixture_repos.sh"

SPACES_CLI="${SPACES_CLI:-$APP_ROOT/.build/debug/spaces}"
SPACES_E2E="${SPACES_E2E:-$APP_ROOT/.build/debug/spacese2e}"
TERMINAL_SERVICE="${SPACESD_EXECUTABLE:-$APP_ROOT/.build/debug/spacesd}"
WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-mobile-latency.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/runtime}"
SERVICE_LOG="$WORK_ROOT/terminal-service.log"
DEVICE_API_LOG="$WORK_ROOT/device-api.log"
PERF_JSONL="$WORK_ROOT/mobile-terminal-performance.jsonl"
SUMMARY_JSON="$WORK_ROOT/terminal-latency-summary.json"
SAMPLES="${SAMPLES:-12}"
NETWORK_PROFILE="local"
NETWORK_RTT_MS="${SPACES_DEVICE_API_NETWORK_RTT_MS:-}"
NETWORK_BANDWIDTH_BPS="${SPACES_DEVICE_API_NETWORK_BANDWIDTH_BPS:-}"
NETWORK_CHUNK_BYTES="${SPACES_DEVICE_API_NETWORK_CHUNK_BYTES:-}"
TERMINAL_TARGETS="${SPACES_MOBILE_LATENCY_TERMINAL_TARGETS:-auto}"
REPORT_ONLY="${SPACES_MOBILE_LATENCY_REPORT_ONLY:-0}"
KEEP_ROOT="${KEEP_ROOT:-0}"
FIXTURE_TEMPLATE_DIR="$APP_ROOT/Tests/fixtures/e2e_demo"
REMOTE_HOST_NAME="${SPACES_E2E_REMOTE_NAME:-Mobile Latency Remote}"
REMOTE_SSH_HOST="${SPACES_E2E_REMOTE_SSH_HOST:-}"
REMOTE_SSH_USER="${SPACES_E2E_REMOTE_SSH_USER:-}"
REMOTE_SSH_PORT="${SPACES_E2E_REMOTE_SSH_PORT:-}"
REMOTE_WORKSPACE_ROOT="${SPACES_E2E_REMOTE_WORKSPACE_ROOT:-~/.spaces/workspaces}"
REMOTE_DAEMON_HOST="${SPACES_E2E_REMOTE_DAEMON_HOST:-$REMOTE_SSH_HOST}"
REMOTE_GIT_ROOT="${SPACES_E2E_REMOTE_GIT_ROOT:-~/.spaces/e2e-git}"
LOCAL_PROJECT_DIR="$WORK_ROOT/local-project"
REMOTE_PROJECT_DIR="$WORK_ROOT/remote-project"
REMOTE_RTT_MS=""

SCENARIOS=(ios-input-latency ios-scrollback-latency)
SELECTED_SCENARIOS=()
DEVICE_API_PID=""

print_usage() {
  cat <<'EOF'
Usage: apps/macos/Tests/e2e_mobile_latency.sh [options]

Options:
  --list                    List available scenarios.
  --scenario NAME           Run only one scenario. May be passed multiple times.
  --network-profile NAME    local or ios-constrained. Defaults to local.
  --rtt-ms N                Override Device API RTT shaping in milliseconds.
  --bandwidth-bps N         Override Device API bandwidth shaping.
  --chunk-bytes N           Override Device API shaping chunk size.
  --terminal-target NAME    auto or local. Defaults to auto.
  --report-only             Report budget failures without failing the script.
  --samples N               Probe count per scenario. Defaults to 12.
  --keep-root               Preserve the temporary profile root.
  --help                    Show this help text.

Network profile defaults:
  local             No Device API shaping.
  ios-constrained   80ms RTT, 8Mbps, 16KB chunks.

Env overrides:
  SPACES_DEVICE_API_NETWORK_RTT_MS
  SPACES_DEVICE_API_NETWORK_BANDWIDTH_BPS
  SPACES_DEVICE_API_NETWORK_CHUNK_BYTES
  SPACES_MOBILE_LATENCY_TERMINAL_TARGETS
  SPACES_MOBILE_LATENCY_REPORT_ONLY
EOF
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  KEEP_ROOT=1
  if [[ -f "$SERVICE_LOG" ]]; then
    printf '\nspacesd log tail:\n' >&2
    tail -n 160 "$SERVICE_LOG" >&2 || true
  fi
  if [[ -f "$DEVICE_API_LOG" ]]; then
    printf '\nDevice API log tail:\n' >&2
    tail -n 160 "$DEVICE_API_LOG" >&2 || true
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
      --network-profile)
        [[ $# -ge 2 ]] || fail "missing value for --network-profile"
        NETWORK_PROFILE="$2"
        shift 2
        ;;
      --samples)
        [[ $# -ge 2 ]] || fail "missing value for --samples"
        SAMPLES="$2"
        shift 2
        ;;
      --rtt-ms)
        [[ $# -ge 2 ]] || fail "missing value for --rtt-ms"
        NETWORK_RTT_MS="$2"
        shift 2
        ;;
      --bandwidth-bps)
        [[ $# -ge 2 ]] || fail "missing value for --bandwidth-bps"
        NETWORK_BANDWIDTH_BPS="$2"
        shift 2
        ;;
      --chunk-bytes)
        [[ $# -ge 2 ]] || fail "missing value for --chunk-bytes"
        NETWORK_CHUNK_BYTES="$2"
        shift 2
        ;;
      --terminal-target)
        [[ $# -ge 2 ]] || fail "missing value for --terminal-target"
        TERMINAL_TARGETS="$2"
        shift 2
        ;;
      --report-only)
        REPORT_ONLY=1
        shift
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

shell_quote() {
  python3 - "$1" <<'PY'
import shlex
import sys
print(shlex.quote(sys.argv[1]))
PY
}

remote_ssh_destination() {
  if [[ -n "$REMOTE_SSH_USER" ]]; then
    printf '%s@%s' "$REMOTE_SSH_USER" "$REMOTE_SSH_HOST"
  else
    printf '%s' "$REMOTE_SSH_HOST"
  fi
}

remote_ssh() {
  [[ -n "$REMOTE_SSH_HOST" ]] || fail "Remote terminal latency requires SPACES_E2E_REMOTE_SSH_HOST."
  local destination
  destination="$(remote_ssh_destination)"
  local -a args=(-o BatchMode=yes)
  if [[ -n "$REMOTE_SSH_PORT" ]]; then
    args+=(-p "$REMOTE_SSH_PORT")
  fi
  ssh "${args[@]}" "$destination" "$@"
}

remote_expand_path() {
  local raw_path="$1"
  local quoted
  quoted="$(shell_quote "$raw_path")"
  remote_ssh "python3 -c 'import os, sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' $quoted"
}

remote_push_url_for_path() {
  local remote_path="$1"
  local user_prefix=""
  local port_part=""
  if [[ -n "$REMOTE_SSH_USER" ]]; then
    user_prefix="$REMOTE_SSH_USER@"
  fi
  if [[ -n "$REMOTE_SSH_PORT" ]]; then
    port_part=":$REMOTE_SSH_PORT"
  fi
  printf 'ssh://%s%s%s%s\n' "$user_prefix" "$REMOTE_SSH_HOST" "$port_part" "$remote_path"
}

prepare_remote_git_origin() {
  local project_dir_for_origin="$1"
  local slug="$2"
  local git_root
  git_root="$(remote_expand_path "$REMOTE_GIT_ROOT")" || return
  local remote_origin="$git_root/$slug.git"
  local quoted_root quoted_origin
  quoted_root="$(shell_quote "$git_root")"
  quoted_origin="$(shell_quote "$remote_origin")"
  remote_ssh "mkdir -p $quoted_root && rm -rf $quoted_origin && git init --bare -q $quoted_origin" || return
  local push_url
  push_url="$(remote_push_url_for_path "$remote_origin")"
  local ssh_command="ssh"
  if [[ -n "$REMOTE_SSH_PORT" ]]; then
    ssh_command+=" -p $REMOTE_SSH_PORT"
  fi
  git -C "$project_dir_for_origin" remote remove origin >/dev/null 2>&1 || true
  git -C "$project_dir_for_origin" remote add origin "$remote_origin" || return
  git -C "$project_dir_for_origin" -c core.sshCommand="$ssh_command" push -q "$push_url" --all || return
}

json_get() {
  local file="$1"
  local expr="$2"
  python3 - "$file" "$expr" <<'PY'
import json
import sys
path, expr = sys.argv[1:3]
with open(path, encoding="utf-8") as fh:
    value = json.load(fh)
for part in expr.split("."):
    if part:
        value = value[part]
print("" if value is None else value)
PY
}

resolve_terminal_targets() {
  case "$TERMINAL_TARGETS" in
    auto)
      TERMINAL_TARGETS="local"
      ;;
    local)
      ;;
    remote|all|local,remote|remote,local)
      fail "Remote terminal latency requires the direct paired-device E2E harness."
      ;;
    *)
      fail "--terminal-target must be auto or local"
      ;;
  esac
}

measure_remote_rtt_ms() {
  [[ "$TERMINAL_TARGETS" == *remote* ]] || return 0
  local host="${REMOTE_DAEMON_HOST:-$REMOTE_SSH_HOST}"
  [[ -n "$host" ]] || return 0
  local ping_output
  ping_output="$(ping -c 5 -q "$host" 2>/dev/null || true)"
  REMOTE_RTT_MS="$(
    python3 - "$ping_output" <<'PY'
import re
import sys

text = sys.argv[1]
match = re.search(r"(?:round-trip|rtt) min/avg/max/(?:stddev|mdev) = [^/]+/([^/]+)/", text)
if match:
    print(match.group(1))
PY
  )"
}

prepare_remote_workspace() {
  return 0
}

cleanup_remote_e2e_host() {
  [[ "$TERMINAL_TARGETS" == *remote* && -n "$REMOTE_SSH_HOST" ]] || return 0
  "$APP_ROOT/scripts/cleanup_linux_spacesd_e2e.sh" >/dev/null 2>&1 || true
}

cleanup() {
  local exit_code=$?
  if [[ -n "$DEVICE_API_PID" ]]; then
    kill "$DEVICE_API_PID" >/dev/null 2>&1 || true
    wait "$DEVICE_API_PID" >/dev/null 2>&1 || true
  fi
  stop_terminal_service_for_runtime_dir "$RUNTIME_DIR" 5 "${SERVICE_PID:-}"
  cleanup_remote_e2e_host
  if [[ "$KEEP_ROOT" == "1" || $exit_code -ne 0 ]]; then
    printf 'Preserved mobile latency root: %s\n' "$WORK_ROOT" >&2
  else
    rm -rf "$WORK_ROOT" || true
  fi
  return "$exit_code"
}
trap cleanup EXIT

parse_args "$@"
[[ "$NETWORK_PROFILE" == "local" || "$NETWORK_PROFILE" == "ios-constrained" ]] || fail "--network-profile must be local or ios-constrained"
[[ "$SAMPLES" =~ ^[0-9]+$ && "$SAMPLES" -gt 0 ]] || fail "--samples must be a positive integer"
[[ -z "$NETWORK_RTT_MS" || "$NETWORK_RTT_MS" =~ ^[0-9]+$ ]] || fail "--rtt-ms must be a non-negative integer"
[[ -z "$NETWORK_BANDWIDTH_BPS" || "$NETWORK_BANDWIDTH_BPS" =~ ^[0-9]+$ ]] || fail "--bandwidth-bps must be a non-negative integer"
[[ -z "$NETWORK_CHUNK_BYTES" || "$NETWORK_CHUNK_BYTES" =~ ^[0-9]+$ ]] || fail "--chunk-bytes must be a non-negative integer"
[[ -x "$SPACES_CLI" ]] || fail "spaces CLI not found at $SPACES_CLI"
[[ -x "$SPACES_E2E" ]] || fail "spacese2e not found at $SPACES_E2E"
[[ -x "$TERMINAL_SERVICE" ]] || fail "spacesd not found at $TERMINAL_SERVICE"
resolve_terminal_targets

mkdir -p "$(dirname "$DB_PATH")" "$RUNTIME_DIR"
touch "$PERF_JSONL"
export SPACES_DB_PATH="$DB_PATH"
export SPACES_RUNTIME_DIR="$RUNTIME_DIR"
export SPACESD_EXECUTABLE="$TERMINAL_SERVICE"
export SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH="$PERF_JSONL"

# terminal create is workspace-scoped; register a fixture project and use its default workspace.
FIXTURE_PROJECT_DIR="$WORK_ROOT/terminal-fixture-project"
mkdir -p "$FIXTURE_PROJECT_DIR"
FIXTURE_WORKSPACE_JSON="$("$SPACES_E2E" register-project --project-dir "$FIXTURE_PROJECT_DIR")"
FIXTURE_WORKSPACE_ID="$(printf '%s' "$FIXTURE_WORKSPACE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

measure_remote_rtt_ms
prepare_remote_workspace

"$TERMINAL_SERVICE" >"$SERVICE_LOG" 2>&1 &
SERVICE_PID=$!

service_socket="$(terminal_service_socket_path_for_runtime_dir "$RUNTIME_DIR")"
service_deadline=$((SECONDS + 15))
while [[ $SECONDS -lt $service_deadline ]]; do
  [[ -S "$service_socket" ]] && break
  sleep 0.1
done
[[ -S "$service_socket" ]] || fail "timed out waiting for spacesd socket"

device_api_env=(SPACES_DEVICE_API_NETWORK_PROFILE="$NETWORK_PROFILE")
if [[ "$NETWORK_PROFILE" == "ios-constrained" ]]; then
  device_api_env+=(
    SPACES_DEVICE_API_NETWORK_RTT_MS="${NETWORK_RTT_MS:-80}"
    SPACES_DEVICE_API_NETWORK_BANDWIDTH_BPS="${NETWORK_BANDWIDTH_BPS:-8000000}"
    SPACES_DEVICE_API_NETWORK_CHUNK_BYTES="${NETWORK_CHUNK_BYTES:-16384}"
  )
fi
if [[ "$NETWORK_PROFILE" == "local" && -n "$NETWORK_RTT_MS" ]]; then
  device_api_env=(SPACES_DEVICE_API_NETWORK_PROFILE="ios-constrained")
  device_api_env+=(
    SPACES_DEVICE_API_NETWORK_RTT_MS="$NETWORK_RTT_MS"
    SPACES_DEVICE_API_NETWORK_BANDWIDTH_BPS="${NETWORK_BANDWIDTH_BPS:-0}"
    SPACES_DEVICE_API_NETWORK_CHUNK_BYTES="${NETWORK_CHUNK_BYTES:-0}"
  )
fi

env "${device_api_env[@]}" "$SPACES_E2E" mobile-serve --host 127.0.0.1 --port 0 >"$DEVICE_API_LOG" 2>&1 &
DEVICE_API_PID="$!"

ready_deadline=$((SECONDS + 15))
while [[ $SECONDS -lt $ready_deadline ]]; do
  grep -q 'Spaces Device API ready' "$DEVICE_API_LOG" 2>/dev/null && break
  sleep 0.1
done
grep -q 'Spaces Device API ready' "$DEVICE_API_LOG" || fail "timed out waiting for device API readiness"

parsed_device_api="$(
python3 - "$DEVICE_API_LOG" <<'PY'
import pathlib
import re
import shlex
import sys
from urllib.parse import parse_qs, urlparse

content = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
port_match = re.search(r"port=(\d+)", content)
link_match = re.search(r"pairing_link=([^\t\n]+)", content)
if not port_match or not link_match:
    raise SystemExit(1)
link = link_match.group(1)
values = parse_qs(urlparse(link).query)
print(f"DEVICE_API_PORT={shlex.quote(port_match.group(1))}")
print(f"PAIRING_LINK={shlex.quote(link)}")
print(f"CERTIFICATE_FINGERPRINT={shlex.quote(values['fp'][0])}")
print(f"PAIRING_CODE={shlex.quote(values['code'][0])}")
print(f"PAIRING_NONCE={shlex.quote(values['nonce'][0])}")
PY
)"
eval "$parsed_device_api"

DEVICE_API_PORT="$DEVICE_API_PORT" \
PAIRING_LINK="$PAIRING_LINK" \
CERTIFICATE_FINGERPRINT="$CERTIFICATE_FINGERPRINT" \
PAIRING_CODE="$PAIRING_CODE" \
PAIRING_NONCE="$PAIRING_NONCE" \
NETWORK_PROFILE="$NETWORK_PROFILE" \
NETWORK_RTT_MS="${NETWORK_RTT_MS:-$([[ "$NETWORK_PROFILE" == "ios-constrained" ]] && printf 80 || printf 0)}" \
REMOTE_RTT_MS="$REMOTE_RTT_MS" \
NETWORK_BANDWIDTH_BPS="${NETWORK_BANDWIDTH_BPS:-$([[ "$NETWORK_PROFILE" == "ios-constrained" ]] && printf 8000000 || printf 0)}" \
NETWORK_CHUNK_BYTES="${NETWORK_CHUNK_BYTES:-$([[ "$NETWORK_PROFILE" == "ios-constrained" ]] && printf 16384 || printf 0)}" \
TERMINAL_TARGETS="$TERMINAL_TARGETS" \
REPORT_ONLY="$REPORT_ONLY" \
SAMPLES="$SAMPLES" \
SUMMARY_JSON="$SUMMARY_JSON" \
PERFORMANCE_LOG_PATH="$PERF_JSONL" \
WORK_ROOT="$WORK_ROOT" \
SPACES_CLI="$SPACES_CLI" \
SPACES_E2E="$SPACES_E2E" \
FIXTURE_WORKSPACE_ID="$FIXTURE_WORKSPACE_ID" \
python3 - "${SELECTED_SCENARIOS[@]}" <<'PY'
import base64
import json
import math
import os
import queue
import re
import sqlite3
import statistics
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

scenarios = sys.argv[1:]
host = "127.0.0.1"
port = int(os.environ["DEVICE_API_PORT"])
certificate_fingerprint = os.environ["CERTIFICATE_FINGERPRINT"]
pairing_code = os.environ["PAIRING_CODE"]
pairing_nonce = os.environ["PAIRING_NONCE"]
# Version-gated pairing: read the daemon's advertised wire-protocol version (pv) from the v3 link.
client_protocol_version = int(re.search(r"[?&]pv=(\d+)", os.environ["PAIRING_LINK"]).group(1))
network_profile = os.environ["NETWORK_PROFILE"]
network_rtt_ms = int(os.environ.get("NETWORK_RTT_MS") or "0")
remote_rtt_ms_text = os.environ.get("REMOTE_RTT_MS") or ""
remote_rtt_ms = float(remote_rtt_ms_text) if remote_rtt_ms_text else None
network_bandwidth_bps = int(os.environ.get("NETWORK_BANDWIDTH_BPS") or "0")
network_chunk_bytes = int(os.environ.get("NETWORK_CHUNK_BYTES") or "0")
terminal_targets = [item.strip() for item in os.environ["TERMINAL_TARGETS"].split(",") if item.strip()]
report_only = os.environ.get("REPORT_ONLY", "0") == "1"
sample_count = int(os.environ["SAMPLES"])
summary_json = Path(os.environ["SUMMARY_JSON"])
performance_log_path = Path(os.environ["PERFORMANCE_LOG_PATH"])
work_root = Path(os.environ["WORK_ROOT"])
spaces_cli = os.environ["SPACES_CLI"]
spacese2e = os.environ["SPACES_E2E"]
# terminal create is workspace-scoped; the harness registered a fixture project and its
# default workspace before this script started, so every session it starts targets that workspace.
fixture_workspace_id = os.environ["FIXTURE_WORKSPACE_ID"]
base_env = os.environ.copy()

events: list[dict] = []
stream_records: list[dict] = []
decode_failures = 0
render_update_baselines: dict[str, dict] = {}
socket_path_cache: dict[str, Path] = {}

budgets = {
    ("ios-input-latency", "local", "local"): {"gross_p95_ms": 100, "target_p95_ms": 75},
    ("ios-scrollback-latency", "local", "local"): {"gross_p95_ms": 100, "target_p95_ms": 75},
    ("ios-input-latency", "ios-constrained", "local"): {"gross_p95_ms": 150, "target_p95_ms": 100},
    ("ios-scrollback-latency", "ios-constrained", "local"): {"gross_p95_ms": 100, "target_p95_ms": 75},
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


def last_performance_event(
    session_id: str,
    source: str,
    name: str,
    after_ns: int,
    before_ns: int | None = None,
    timeout: float = 1.0,
    require_render_payload: bool = True,
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
            if require_render_payload:
                has_render_payload = attributes.get("render_frame") == "1" or attributes.get("render_update") == "1"
                if not has_render_payload or attributes.get("drop_reason") not in (None, "none"):
                    continue
            candidates.append((emitted_ns, record))
        if candidates:
            emitted_ns, record = max(candidates, key=lambda item: item[0])
            return record, emitted_ns
        time.sleep(0.02)
    return None


def extract_session_id(output: str) -> str:
    match = re.search(r"^Started terminal session ([0-9A-Fa-f-]{36})(?:\s|$)", output, re.MULTILINE)
    if not match:
        raise RuntimeError(f"failed to parse session id from: {output}")
    return match.group(1).upper()


def control_socket_path(session_id: str) -> Path:
    cached = socket_path_cache.get(session_id)
    if cached is not None:
        return cached
    result = subprocess.run(
        [spacese2e, "profile-socket-paths", "--session-id", session_id],
        env=base_env,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    path = Path(json.loads(result.stdout)["sessionControlSocketPath"])
    socket_path_cache[session_id] = path
    return path


def wait_for_session_id_by_title(title: str, timeout: float = 10) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with sqlite3.connect(os.environ["SPACES_DB_PATH"]) as db:
            rows = db.execute(
                "SELECT session_id, root_directory FROM terminal_sessions WHERE title = ? ORDER BY created_at DESC",
                (title,),
            ).fetchall()
        for session_id, root_directory in rows:
            if control_socket_path(session_id).exists():
                return session_id.upper()
        time.sleep(0.1)
    raise TimeoutError(f"timed out recovering session id for title {title}")


def start_terminal(title: str, command: str, terminal_target: str) -> str:
    try:
        completed = run(
            [spaces_cli, "terminal", "create", "--workspace", fixture_workspace_id, "--command", command, "--title", title],
            timeout=20,
        )
        return extract_session_id(completed.stdout)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        try:
            return wait_for_session_id_by_title(title)
        except TimeoutError:
            stdout = getattr(error, "stdout", None) or getattr(error, "output", None) or ""
            stderr = getattr(error, "stderr", None) or ""
            raise RuntimeError(
                f"failed to start terminal title={title!r}\nstdout:\n{stdout}\nstderr:\n{stderr}"
            ) from error


def typed_device_api_payload(payload: dict) -> dict:
    command = payload.get("command")
    if isinstance(command, dict):
        return payload
    command_payload = {key: value for key, value in payload.items() if key not in ("command", "authToken", "clientApp")}
    if command in ("attach", "detach", "heartbeat", "takeover", "send", "key", "clear", "clearScreen", "resize", "scroll"):
        command_payload["action"] = "clearScreen" if command == "clear" else command
        command_payload.setdefault("appendNewline", False)
        command_payload.setdefault("asPaste", False)
        typed_command = {"terminalControl": command_payload}
    else:
        typed_command = {command: command_payload}
    request = {key: value for key, value in payload.items() if key in ("authToken", "clientApp")}
    request["command"] = typed_command
    return request


def device_api_result(response: dict, kind: str) -> dict:
    result = response.get("result")
    assert isinstance(result, dict) and set(result) == {kind}, {"kind": kind, "response": response}
    payload = result[kind]
    assert isinstance(payload, dict), {"kind": kind, "response": response}
    return payload


def device_api_session_state(response: dict) -> dict:
    if "sessionState" in response:
        return response["sessionState"]
    return device_api_result(response, "terminalState")


def device_api_request(payload: dict) -> tuple[dict, float]:
    payload = typed_device_api_payload(payload)
    started = time.perf_counter()
    completed = run(
        [
            spacese2e,
            "mobile-request",
            "--host",
            host,
            "--port",
            str(port),
            "--certificate-fingerprint=" + certificate_fingerprint,
            "--request-json",
            json.dumps(payload),
        ],
        timeout=20,
    )
    return json.loads(completed.stdout), (time.perf_counter() - started) * 1000


def device_api_connect_stream(payload: dict) -> subprocess.Popen:
    payload = typed_device_api_payload(payload)
    return subprocess.Popen(
        [
            spacese2e,
            "mobile-request",
            "--host",
            host,
            "--port",
            str(port),
            "--certificate-fingerprint=" + certificate_fingerprint,
            "--request-json",
            json.dumps(payload),
            "--stream",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=base_env,
    )


def request(payload: dict, terminal_target: str = "local") -> tuple[dict, float]:
    return device_api_request(payload)


def connect_stream(payload: dict, terminal_target: str) -> subprocess.Popen:
    return device_api_connect_stream(payload)


class StreamLineReader:
    def __init__(self, stream: subprocess.Popen):
        assert stream.stdout is not None
        self.stream = stream
        self.queue: queue.Queue[tuple[str, object, int | None]] = queue.Queue()
        self.done = threading.Event()
        self.latest_payload: dict | None = None
        self.latest_received_ns: int | None = None
        self.thread = threading.Thread(target=self._read_loop, name="mobile-stream-reader", daemon=True)
        self.thread.start()

    def _read_loop(self) -> None:
        global decode_failures
        assert self.stream.stdout is not None
        try:
            for line in self.stream.stdout:
                received_ns = now_ns()
                line_bytes = len(line.encode("utf-8"))
                try:
                    payload = json.loads(line)
                except json.JSONDecodeError:
                    decode_failures += 1
                    stream_records.append({"received_ns": received_ns, "bytes": line_bytes, "decode_failed": True})
                    continue
                raw_render_update = bool(payload.get("renderUpdate"))
                payload = materialize_render_update(payload)
                if payload.get("_renderUpdateDecodeFailed"):
                    decode_failures += 1
                render_meta = dict(payload.get("_renderUpdateMeta") or {})
                if render_meta:
                    render_meta["json_payload_bytes"] = line_bytes
                    payload["_renderUpdateMeta"] = render_meta
                materialized_snapshot = bool(payload.get("_materializedRenderSnapshot"))
                self.latest_payload = payload
                self.latest_received_ns = received_ns
                stream_records.append(
                    {
                        "received_ns": received_ns,
                        "bytes": line_bytes,
                        "decode_failed": False,
                        "render_update_decode_failed": bool(payload.get("_renderUpdateDecodeFailed")),
                        "reason": payload.get("reason"),
                        "render_update": raw_render_update,
                        "frame_kind": render_meta.get("frame_kind"),
                        "fallback_reason": render_meta.get("fallback_reason"),
                        "changed_cell_count": render_meta.get("changed_cell_count"),
                        "render_update_bytes": render_meta.get("render_update_bytes") or 0,
                        "json_payload_bytes": line_bytes,
                        "materialized_snapshot": materialized_snapshot,
                    }
                )
                self.queue.put(("payload", payload, received_ns))
        except Exception as error:
            self.queue.put(("error", repr(error), None))
        finally:
            self.done.set()


def stream_reader(stream: subprocess.Popen) -> StreamLineReader:
    reader = getattr(stream, "_spaces_reader", None)
    if reader is None:
        reader = StreamLineReader(stream)
        setattr(stream, "_spaces_reader", reader)
    return reader


def latest_stream_payload(stream: subprocess.Popen) -> tuple[dict, int] | None:
    reader = stream_reader(stream)
    if reader.latest_payload is None or reader.latest_received_ns is None:
        return None
    return reader.latest_payload, reader.latest_received_ns


# GhosttyRenderUpdate.currentVersion. Bumped in lockstep with the Swift codec; there is deliberately no
# compatibility path for older versions, so a mismatch is rejected rather than misread.
RENDER_UPDATE_VERSION = 5

# The two high bits of a cell's wire flags word are codec-reserved payload markers, not style flags: the
# cell is followed, in its block's sparse text section, by its grapheme cluster (bit 15) and/or its OSC 8
# link URL (bit 14). Style flags occupy bits 0-10 and never reach these, so a decoder strips them off the
# flags value it reports.
CLUSTER_PAYLOAD_FLAG = 1 << 15
LINK_PAYLOAD_FLAG = 1 << 14
PAYLOAD_FLAG_MASK = CLUSTER_PAYLOAD_FLAG | LINK_PAYLOAD_FLAG


class RenderUpdateReader:
    nil_revision = (1 << 64) - 1

    def __init__(self, data: bytes):
        self.data = data
        self.offset = 0

    def read(self, count: int) -> bytes:
        if count < 0 or self.offset + count > len(self.data):
            raise ValueError("truncated render update")
        value = self.data[self.offset : self.offset + count]
        self.offset += count
        return value

    def u8(self) -> int:
        return self.read(1)[0]

    def u16(self) -> int:
        return int.from_bytes(self.read(2), "little", signed=False)

    def u32(self) -> int:
        return int.from_bytes(self.read(4), "little", signed=False)

    def u64(self) -> int:
        return int.from_bytes(self.read(8), "little", signed=False)

    def i32(self) -> int:
        return int.from_bytes(self.read(4), "little", signed=True)

    def revision(self) -> int | None:
        value = self.u64()
        return None if value == self.nil_revision else value

    def string(self) -> str:
        return self.read(self.u16()).decode("utf-8")


def decode_render_update(payload: dict) -> dict | None:
    encoded = payload.get("renderUpdate")
    if not encoded:
        return None
    reader = RenderUpdateReader(base64.b64decode(encoded))
    if reader.read(4) != b"GRTU":
        raise ValueError("invalid render update magic")
    version = reader.u8()
    if version != RENDER_UPDATE_VERSION:
        raise ValueError(f"unsupported render update version {version} (expected {RENDER_UPDATE_VERSION})")
    kind_byte = reader.u8()
    _ = reader.u16()
    session_revision = reader.revision()
    base_revision = reader.revision()
    target_revision = reader.revision()
    owner_epoch = reader.u64()
    columns = reader.u16()
    rows = reader.u16()
    fallback_reason = reader.string() or None
    if kind_byte == 1:
        snapshot = read_render_update_snapshot(reader, columns, rows)
        kind = "full"
    elif kind_byte == 2:
        snapshot = None
        kind = "delta"
    elif kind_byte == 3:
        return {
            "kind": "resync_required",
            "sessionRevision": session_revision,
            "baseRevision": base_revision,
            "targetRevision": target_revision,
            "ownerEpoch": owner_epoch,
            "columns": columns,
            "rows": rows,
            "fallbackReason": fallback_reason,
        }
    else:
        raise ValueError(f"invalid render update kind {kind_byte}")
    update = {
        "kind": kind,
        "sessionRevision": session_revision,
        "baseRevision": base_revision,
        "targetRevision": target_revision,
        "ownerEpoch": owner_epoch,
        "columns": columns,
        "rows": rows,
        "fallbackReason": fallback_reason,
        "snapshot": snapshot,
    }
    if kind == "delta":
        update["delta"] = read_render_update_delta(reader, base_revision, target_revision, owner_epoch, columns, rows)
    return update


def render_update_binary_size(payload: dict) -> int:
    encoded = payload.get("renderUpdate")
    if not encoded:
        return 0
    try:
        return len(base64.b64decode(encoded))
    except Exception:
        return 0


def render_update_metadata(payload: dict, update: dict) -> dict:
    changed_cell_count = 0
    if update["kind"] == "full":
        changed_cell_count = len((update.get("snapshot") or {}).get("cells") or [])
    elif update["kind"] == "delta":
        changed_cell_count = int((update.get("delta") or {}).get("changedCellCount") or 0)
    return {
        "reason": payload.get("reason"),
        "frame_kind": update["kind"],
        "fallback_reason": update.get("fallbackReason"),
        "changed_cell_count": changed_cell_count,
        "render_update_bytes": render_update_binary_size(payload),
    }


def read_render_update_cell_block(reader: RenderUpdateReader, count: int) -> list[dict]:
    """Reads one block of `count` 14-byte cells plus the sparse text section that follows it.

    That section holds one entry per payload flag bit the cells set, in cell order and cluster before link,
    each `(UInt32 offset within the block, UInt16 utf8 byte count, bytes)`; a block whose cells set no
    payload bits is followed by nothing at all. This harness renders base codepoints only, so the payload
    text is read purely to keep the reader aligned with the rest of the frame.
    """
    cells = []
    flagged = []
    for index in range(count):
        codepoint = reader.u32()
        foreground_rgb = reader.u32()
        background_rgb = reader.u32()
        flags = reader.u16()
        if flags & PAYLOAD_FLAG_MASK:
            flagged.append((index, flags))
        cells.append(
            {
                "codepoint": codepoint,
                "foregroundRGB": foreground_rgb,
                "backgroundRGB": background_rgb,
                "flags": flags & ~PAYLOAD_FLAG_MASK,
            }
        )
    for index, flags in flagged:
        for payload_flag in (CLUSTER_PAYLOAD_FLAG, LINK_PAYLOAD_FLAG):
            if not flags & payload_flag:
                continue
            offset = reader.u32()
            if offset != index:
                raise ValueError(f"render update cell payload names offset {offset}, expected {index}")
            reader.read(reader.u16())
    return cells


def read_render_update_snapshot(reader: RenderUpdateReader, columns: int, rows: int) -> dict:
    cursor_column = reader.u16()
    cursor_row = reader.u16()
    cursor_visible = reader.u8() != 0
    default_foreground_rgb = reader.u32()
    default_background_rgb = reader.u32()
    _ = reader.u8()  # mouse reporting active
    _ = reader.u8()  # mouse shift capture
    _ = reader.read(17)  # selection and scrollbar section (flag byte, four coordinates, two scrollbar counters)
    cell_count = reader.u32()
    return {
        "columns": columns,
        "rows": rows,
        "cursorColumn": cursor_column,
        "cursorRow": cursor_row,
        "cursorVisible": cursor_visible,
        "defaultForegroundRGB": default_foreground_rgb,
        "defaultBackgroundRGB": default_background_rgb,
        "cells": read_render_update_cell_block(reader, cell_count),
    }


def read_render_update_delta(
    reader: RenderUpdateReader, base_revision: int | None, target_revision: int | None, owner_epoch: int, columns: int, rows: int
) -> dict:
    cursor_column = reader.u16()
    cursor_row = reader.u16()
    cursor_visible = reader.u8() != 0
    default_foreground_rgb = reader.u32()
    default_background_rgb = reader.u32()
    _ = reader.u8()  # mouse reporting active
    _ = reader.u8()  # mouse shift capture
    _ = reader.read(17)  # selection and scrollbar section (flag byte, four coordinates, two scrollbar counters)
    _ = reader.u8()  # scroll rects overflowed
    changed_cell_count = reader.u32()
    delta = {
        "baseRevision": base_revision,
        "targetRevision": target_revision,
        "ownerEpoch": owner_epoch,
        "columns": columns,
        "rows": rows,
        "cursorColumn": cursor_column,
        "cursorRow": cursor_row,
        "cursorVisible": cursor_visible,
        "defaultForegroundRGB": default_foreground_rgb,
        "defaultBackgroundRGB": default_background_rgb,
        "changedCellCount": changed_cell_count,
        "scrollRects": [],
        "replaceCellRuns": [],
    }
    for _ in range(reader.u32()):
        delta["scrollRects"].append(
            {
                "rowStart": reader.u16(),
                "rowCount": reader.u16(),
                "columnStart": reader.u16(),
                "columnCount": reader.u16(),
                "deltaRows": reader.i32(),
                "deltaColumns": reader.i32(),
            }
        )
    for _ in range(reader.u32()):
        row = reader.u16()
        column = reader.u16()
        cell_count = reader.u16()
        delta["replaceCellRuns"].append(
            {
                "row": row,
                "column": column,
                "cells": read_render_update_cell_block(reader, cell_count),
            }
        )
    return delta


def render_update_blank_cell(delta: dict) -> dict:
    return {
        "codepoint": 0,
        "foregroundRGB": delta["defaultForegroundRGB"],
        "backgroundRGB": delta["defaultBackgroundRGB"],
        "flags": 0,
    }


def render_update_cell_index(row: int, column: int, columns: int) -> int:
    return row * columns + column


def apply_render_update_delta(delta: dict, snapshot: dict) -> dict:
    columns = int(snapshot.get("columns") or 0)
    rows = int(snapshot.get("rows") or 0)
    if columns != delta["columns"] or rows != delta["rows"]:
        raise ValueError("render update dimension mismatch")
    cells = list(snapshot.get("cells") or [])
    if len(cells) < columns * rows:
        raise ValueError("render update baseline grid is incomplete")
    cells = cells[: columns * rows]
    blank = render_update_blank_cell(delta)
    for operation in delta["scrollRects"]:
        row_start = operation["rowStart"]
        row_count = operation["rowCount"]
        column_start = operation["columnStart"]
        column_count = operation["columnCount"]
        if row_start < 0 or column_start < 0 or row_start + row_count > rows or column_start + column_count > columns:
            raise ValueError("invalid render update scroll rect")
        original = list(cells)
        for row in range(row_start, row_start + row_count):
            for column in range(column_start, column_start + column_count):
                cells[render_update_cell_index(row, column, columns)] = blank
        for source_row in range(row_start, row_start + row_count):
            for source_column in range(column_start, column_start + column_count):
                destination_row = source_row + operation["deltaRows"]
                destination_column = source_column + operation["deltaColumns"]
                if (
                    destination_row < row_start
                    or destination_row >= row_start + row_count
                    or destination_column < column_start
                    or destination_column >= column_start + column_count
                ):
                    continue
                cells[render_update_cell_index(destination_row, destination_column, columns)] = original[
                    render_update_cell_index(source_row, source_column, columns)
                ]
    for run in delta["replaceCellRuns"]:
        row = run["row"]
        column = run["column"]
        run_cells = run["cells"]
        if row < 0 or row >= rows or column < 0 or column + len(run_cells) > columns:
            raise ValueError("invalid render update cell run")
        start = render_update_cell_index(row, column, columns)
        cells[start : start + len(run_cells)] = run_cells
    return {
        "columns": columns,
        "rows": rows,
        "cursorColumn": delta["cursorColumn"],
        "cursorRow": delta["cursorRow"],
        "cursorVisible": delta["cursorVisible"],
        "defaultForegroundRGB": delta["defaultForegroundRGB"],
        "defaultBackgroundRGB": delta["defaultBackgroundRGB"],
        "cells": cells,
    }


def materialize_render_update(payload: dict) -> dict:
    session_id = payload.get("sessionID")
    if not session_id or not payload.get("renderUpdate"):
        return payload
    materialized = dict(payload)
    try:
        update = decode_render_update(payload)
    except Exception as error:
        materialized["_renderUpdateDecodeFailed"] = str(error)
        return materialized
    if update is None or update["kind"] == "resync_required":
        if update is not None:
            materialized["_renderUpdateMeta"] = render_update_metadata(payload, update)
        return materialized
    materialized["_renderUpdateMeta"] = render_update_metadata(payload, update)
    if update["kind"] == "full":
        baseline = {
            "sessionRevision": update["sessionRevision"],
            "ownerEpoch": update["ownerEpoch"],
            "snapshot": update["snapshot"],
        }
    else:
        baseline = render_update_baselines.get(session_id)
        if not baseline:
            return materialized
        delta = update["delta"]
        if baseline.get("sessionRevision") != delta["baseRevision"] or baseline.get("ownerEpoch") != delta["ownerEpoch"]:
            return materialized
        try:
            snapshot = apply_render_update_delta(delta, baseline["snapshot"])
        except Exception:
            return materialized
        baseline = {
            "sessionRevision": delta["targetRevision"],
            "ownerEpoch": delta["ownerEpoch"],
            "snapshot": snapshot,
        }
    render_update_baselines[session_id] = baseline
    materialized["_materializedRenderSnapshot"] = baseline["snapshot"]
    materialized["_materializedSessionRevision"] = baseline["sessionRevision"]
    materialized["_materializedOwnerEpoch"] = baseline["ownerEpoch"]
    return materialized


def plain_text(payload: dict) -> str:
    snapshot = payload.get("_materializedRenderSnapshot") or {}
    columns = int(snapshot.get("columns") or 0)
    rows = int(snapshot.get("rows") or 0)
    cells = snapshot.get("cells") or []
    if columns <= 0 or rows <= 0 or len(cells) < columns * rows:
        return ""
    lines: list[str] = []
    for row in range(rows):
        start = row * columns
        row_cells = cells[start : start + columns]
        chars = []
        for cell in row_cells:
            codepoint = int(cell.get("codepoint") or 0)
            chars.append(chr(codepoint) if codepoint > 0 else " ")
        lines.append("".join(chars).rstrip())
    return "\n".join(lines)


def wait_for_line(stream: subprocess.Popen, predicate, timeout: float = 10) -> tuple[dict, int]:
    reader = stream_reader(stream)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        remaining = max(0.0, deadline - time.monotonic())
        try:
            kind, value, received_ns = reader.queue.get(timeout=remaining)
        except queue.Empty:
            continue
        if kind == "error":
            raise RuntimeError(f"stream reader failed: {value}")
        payload = value
        assert isinstance(payload, dict)
        assert received_ns is not None
        if predicate(payload):
            return payload, received_ns
        if reader.done.is_set() and reader.queue.empty() and stream.poll() is not None:
            break
    stderr = ""
    if stream.stderr is not None and stream.poll() is not None:
        try:
            stderr = stream.stderr.read()
        except Exception:
            stderr = ""
    detail = f": {stderr.strip()}" if stderr.strip() else ""
    raise TimeoutError(f"timed out waiting for streamed terminal state{detail}")


client_app = {
    "installationID": str(uuid.uuid4()).upper(),
    "bundleID": "dev.usespaces.spacesmobile",
    "platform": "ios",
    "deviceName": "iPhone Latency Harness",
    "appVersion": "1.0",
}

pair_response, _ = device_api_request(
    {
        "command": "pair",
        "pairingCode": pairing_code,
        "pairingNonce": pairing_nonce,
        "clientProtocolVersion": client_protocol_version,
        "clientApp": client_app,
    }
)
assert pair_response["ok"], pair_response
auth_token = device_api_result(pair_response, "issuedAuthToken")["authToken"]


def attach_pair(session_id: str, terminal_target: str) -> tuple[str, str, subprocess.Popen | None]:
    desktop_client_id = str(uuid.uuid4()).upper()
    desktop_owner = {
        "id": desktop_client_id,
        "kind": "localWindow",
        "identity": {"label": "Spaces window", "hostName": "localhost", "deviceName": "Mac", "networkAddress": "127.0.0.1"},
        "connectedAt": "2026-06-02T12:00:00Z",
        "disconnectedAt": None,
    }
    response, _ = request(
        {
            "command": "attach",
            "authToken": auth_token,
            "clientApp": client_app,
            "sessionID": session_id,
            "client": desktop_owner,
            "attachmentMode": "owner",
        },
        terminal_target,
    )
    assert response["ok"], response

    mobile_client_id = str(uuid.uuid4()).upper()
    mobile_client = {
        "id": mobile_client_id,
        "kind": "remoteViewer",
        "identity": {"label": "iPhone Latency Harness", "deviceName": "iPhone Latency Harness", "networkAddress": "127.0.0.1"},
        "connectedAt": "2026-06-02T12:00:00Z",
        "disconnectedAt": None,
    }
    response, _ = request(
        {
            "command": "attach",
            "authToken": auth_token,
            "clientApp": client_app,
            "sessionID": session_id,
            "client": mobile_client,
            "attachmentMode": "viewer",
        },
        terminal_target,
    )
    assert response["ok"], response
    def owner_is_mobile(payload: dict) -> bool:
        snapshot = payload.get("attachmentSnapshot") or {}
        return any(
            attachment.get("mode") == "owner"
            and attachment.get("detachedAt") is None
            and attachment.get("clientID") == mobile_client_id
            for attachment in snapshot.get("attachments") or []
        )

    stream = None
    stream = connect_stream(
        {
            "command": "subscribe",
            "authToken": auth_token,
            "clientApp": client_app,
            "sessionID": session_id,
            "clientID": mobile_client_id,
        },
        terminal_target,
    )
    wait_for_line(stream, lambda payload: payload.get("sessionID") == session_id, timeout=30)

    try:
        response, _ = request(
            {
                "command": "takeover",
                "authToken": auth_token,
                "clientApp": client_app,
                "sessionID": session_id,
                "clientID": mobile_client_id,
            },
            terminal_target,
        )
        assert response["ok"], response
    except subprocess.CalledProcessError:
        pass

    wait_for_line(stream, owner_is_mobile, timeout=30)
    return desktop_client_id, mobile_client_id, stream


def fetch_state(session_id: str, terminal_target: str = "local") -> dict:
    response, _ = request(
        {
            "command": "state",
            "authToken": auth_token,
            "clientApp": client_app,
            "sessionID": session_id,
        },
        terminal_target,
    )
    assert response["ok"], response
    return materialize_render_update(device_api_session_state(response))


def poll_state_predicate(session_id: str, predicate, timeout: float = 10, terminal_target: str = "local") -> tuple[dict, int]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = fetch_state(session_id, terminal_target)
        if predicate(state):
            return state, now_ns()
        time.sleep(0.1)
    raise TimeoutError("timed out waiting for terminal state predicate")


def poll_state_contains(session_id: str, needle: str, timeout: float = 10, terminal_target: str = "local") -> tuple[dict, int]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = fetch_state(session_id, terminal_target)
        if needle in plain_text(state):
            return state, now_ns()
        time.sleep(0.1)
    raise TimeoutError(f"timed out waiting for terminal state containing {needle!r}")


def poll_state_text_change(session_id: str, before_text: str, timeout: float = 10, terminal_target: str = "local") -> tuple[dict, int]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = fetch_state(session_id, terminal_target)
        text = plain_text(state)
        if text and text != before_text:
            return state, now_ns()
        time.sleep(0.1)
    raise TimeoutError("timed out waiting for terminal state text change")


def optional_state_text_change(session_id: str, before_text: str, timeout: float = 2, terminal_target: str = "local") -> tuple[dict, int] | None:
    try:
        return poll_state_text_change(session_id, before_text, timeout=timeout, terminal_target=terminal_target)
    except TimeoutError:
        return None


def send_scroll_request(session_id: str, mobile_client_id: str, scroll_vertical: float, terminal_target: str = "local") -> tuple[dict, float]:
    return request(
        {
            "command": "scroll",
            "authToken": auth_token,
            "clientApp": client_app,
            "sessionID": session_id,
            "clientID": mobile_client_id,
            "scrollVertical": scroll_vertical,
        },
        terminal_target,
    )


def close_stream(stream: subprocess.Popen) -> None:
    stream.terminate()
    try:
        stream.wait(timeout=5)
    except subprocess.TimeoutExpired:
        stream.kill()


def percentile(values: list[float], pct: float) -> float:
    ordered = sorted(values)
    return ordered[max(math.ceil(len(ordered) * pct) - 1, 0)]


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
        "direct_command_request": summarize_latencies(measurements, "direct_command_request_ms"),
        "event_to_frame_publish": summarize_latencies(measurements, "event_to_frame_publish_ms"),
        "event_to_host_publish": summarize_latencies(measurements, "event_to_host_publish_ms"),
        "host_publish_to_relay_read": summarize_latencies(measurements, "host_publish_to_relay_read_ms"),
        "relay_read_to_network_send_begin": summarize_latencies(measurements, "relay_read_to_network_send_begin_ms"),
        "network_send_begin_to_stream_visible": summarize_latencies(measurements, "network_send_begin_to_stream_visible_ms"),
        "frame_publish_to_visible": summarize_latencies(measurements, "frame_publish_to_visible_ms"),
        "host_publish_to_client_visible": summarize_latencies(measurements, "host_publish_to_client_visible_ms"),
        "rpc_end_to_render_visible": summarize_latencies(measurements, "rpc_end_to_render_visible_ms"),
        "event_to_visible_total": summarize_latencies(measurements, "event_to_visible_ms"),
    }


def visible_render_metadata(payload: dict) -> dict:
    meta = payload.get("_renderUpdateMeta") or {}
    return {
        "visible_reason": meta.get("reason"),
        "visible_frame_kind": meta.get("frame_kind"),
        "visible_fallback_reason": meta.get("fallback_reason"),
        "visible_changed_cell_count": meta.get("changed_cell_count"),
        "visible_render_update_bytes": meta.get("render_update_bytes"),
        "visible_json_payload_bytes": meta.get("json_payload_bytes"),
    }


def summarize_visible_render_samples(measurements: list[dict]) -> dict:
    kinds = [item.get("visible_frame_kind") for item in measurements if item.get("visible_frame_kind")]
    byte_counts = [
        int(item["visible_render_update_bytes"])
        for item in measurements
        if item.get("visible_render_update_bytes") is not None
    ]
    return {
        "visible_sample_count": len(kinds),
        "full_visible_sample_count": sum(1 for kind in kinds if kind == "full"),
        "delta_visible_sample_count": sum(1 for kind in kinds if kind == "delta"),
        "resync_required_visible_sample_count": sum(1 for kind in kinds if kind == "resync_required"),
        "median_visible_render_update_bytes": round(statistics.median(byte_counts), 1) if byte_counts else None,
    }


def device_api_latency_split(session_id: str, begin_ns: int, frame_publish_ns: int | None, visible_ns: int) -> dict:
    after_ns = frame_publish_ns if frame_publish_ns is not None else begin_ns
    relay_read = last_performance_event(session_id, "device-api", "stream_relay_read", after_ns, before_ns=visible_ns)
    relay_read_ns = relay_read[1] if relay_read else None
    network_send_begin = last_performance_event(
        session_id,
        "device-api",
        "stream_network_send_begin",
        relay_read_ns if relay_read_ns is not None else after_ns,
        before_ns=visible_ns,
    )
    network_send_begin_ns = network_send_begin[1] if network_send_begin else None
    return {
        "host_publish_to_relay_read_ms": (
            ms_between(frame_publish_ns, relay_read_ns) if frame_publish_ns is not None and relay_read_ns is not None else None
        ),
        "relay_read_to_network_send_begin_ms": (
            ms_between(relay_read_ns, network_send_begin_ns)
            if relay_read_ns is not None and network_send_begin_ns is not None
            else None
        ),
        "network_send_begin_to_stream_visible_ms": (
            ms_between(network_send_begin_ns, visible_ns) if network_send_begin_ns is not None else None
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


def send_typed_text(session_id: str, client_id: str, text: str, terminal_target: str):
    """Types characters the way the app does: `GhosttyRemoteTerminalHostView.insertText` forwards them as
    a `send` carrying only the characters, with no newline.

    Deliberately NOT `appendNewline`. That is the submit path `spaces terminal send --submit` uses, and it
    paces an unframed submit's carriage return by 500ms and holds the following write back by another 500ms
    (`TerminalControlInputSequencer`, issue #187) so an agent composer reads the Enter as its own keystroke.
    No iOS input path pays that: Return is a separate `key` request from both the keyboard and the composer.
    Measuring input latency through the submit path measures that pacing instead of the render round trip.
    """
    return request(
        {
            "command": "send",
            "authToken": auth_token,
            "clientApp": client_app,
            "sessionID": session_id,
            "clientID": client_id,
            "text": text,
        },
        terminal_target,
    )


def send_return_key(session_id: str, client_id: str, terminal_target: str) -> None:
    """Presses Return the way the app does: `insertText` turns a newline into `sendAccessoryKey("enter")`,
    and `sendComposedMessage` ends its send with the same `key` request."""
    response, _ = request(
        {
            "command": "key",
            "authToken": auth_token,
            "clientApp": client_app,
            "sessionID": session_id,
            "clientID": client_id,
            "key": "enter",
        },
        terminal_target,
    )
    assert response["ok"], response


def run_ios_input_latency(terminal_target: str) -> dict:
    scenario = "ios-input-latency"
    title = f"{scenario}-{network_profile}-{terminal_target}-{uuid.uuid4().hex[:8]}"
    session_id = start_terminal(title, "cat", terminal_target)
    _, mobile_client_id, stream = attach_pair(session_id, terminal_target)
    measurements = []
    try:
        warmup_token = f"ioswarmup{uuid.uuid4().hex[:8]}"
        response, _ = send_typed_text(session_id, mobile_client_id, warmup_token, terminal_target)
        assert response["ok"], response
        wait_for_line(stream, lambda payload, token=warmup_token: token in plain_text(payload), timeout=10)
        send_return_key(session_id, mobile_client_id, terminal_target)
        wait_for_line(stream, lambda payload, token=warmup_token: plain_text(payload).count(token) >= 2, timeout=10)

        for index in range(sample_count):
            probe_id = f"ios-input-{index + 1:03d}-{uuid.uuid4().hex[:8]}"
            token = f"ioslatency{index + 1:03d}{uuid.uuid4().hex[:6]}"
            begin_ns = now_ns()
            event(
                "ios_input_begin",
                scenario,
                probe_id,
                begin_ns,
                token=token,
                network_profile=network_profile,
                terminal_target=terminal_target,
            )
            enqueue_ns = now_ns()
            event("ios_input_enqueue", scenario, probe_id, enqueue_ns)
            flush_ns = now_ns()
            event("ios_input_flush", scenario, probe_id, flush_ns)
            rpc_begin_ns = now_ns()
            event("ios_input_rpc_begin", scenario, probe_id, rpc_begin_ns, enqueue_to_rpc_begin_ms=ms_between(enqueue_ns, rpc_begin_ns))
            response, rpc_ms = send_typed_text(session_id, mobile_client_id, token, terminal_target)
            assert response["ok"], response
            rpc_end_ns = now_ns()
            rpc_duration_ms = ms_between(rpc_begin_ns, rpc_end_ns)
            event("ios_input_rpc_end", scenario, probe_id, rpc_end_ns, rpc_ms=rpc_duration_ms)
            direct_command = last_performance_event(
                session_id,
                "ios-direct-daemon",
                "direct_command_request",
                rpc_begin_ns,
                before_ns=rpc_end_ns,
                require_render_payload=False,
            )
            visible_payload, visible_ns = wait_for_line(stream, lambda payload, token=token: token in plain_text(payload), timeout=10)
            visible_meta = visible_render_metadata(visible_payload)
            frame_publish = last_performance_event(session_id, "mac-host", "render_frame_payload_publish", begin_ns, before_ns=visible_ns)
            frame_publish_ns = frame_publish[1] if frame_publish else None
            event_to_frame_publish_ms = ms_between(begin_ns, frame_publish_ns) if frame_publish_ns is not None else None
            frame_publish_to_visible_ms = ms_between(frame_publish_ns, visible_ns) if frame_publish_ns is not None else None
            device_api_split = device_api_latency_split(session_id, begin_ns, frame_publish_ns, visible_ns)
            if frame_publish_ns is not None:
                event(
                    "ios_input_frame_published",
                    scenario,
                    probe_id,
                    frame_publish_ns,
                    event_to_frame_publish_ms=event_to_frame_publish_ms,
                    frame_publish_to_visible_ms=frame_publish_to_visible_ms,
                    target_revision=(frame_publish[0].get("attributes") or {}).get("target_revision"),
                )
            event(
                "ios_input_echo_visible",
                scenario,
                probe_id,
                visible_ns,
                rpc_end_to_render_visible_ms=ms_between(rpc_end_ns, visible_ns),
                event_to_visible_ms=ms_between(begin_ns, visible_ns),
                visible_reason=visible_meta["visible_reason"],
                visible_frame_kind=visible_meta["visible_frame_kind"],
                visible_fallback_reason=visible_meta["visible_fallback_reason"],
                visible_changed_cell_count=visible_meta["visible_changed_cell_count"],
                visible_render_update_bytes=visible_meta["visible_render_update_bytes"],
                visible_json_payload_bytes=visible_meta["visible_json_payload_bytes"],
            )
            measurement = {
                "sample_index": index + 1,
                "probe_id": probe_id,
                "token": token,
                "enqueue_to_rpc_begin_ms": ms_between(enqueue_ns, rpc_begin_ns),
                "flush_to_rpc_begin_ms": ms_between(flush_ns, rpc_begin_ns),
                "rpc_ms": round(rpc_ms, 3),
                "direct_command_request_ms": (direct_command[0].get("elapsedMS") if direct_command else None),
                "direct_command_connection_reused": ((direct_command[0].get("attributes") or {}).get("connection_reused") if direct_command else None),
                "rpc_end_to_render_visible_ms": ms_between(rpc_end_ns, visible_ns),
                "event_to_frame_publish_ms": event_to_frame_publish_ms,
                "event_to_host_publish_ms": event_to_frame_publish_ms,
                "host_publish_to_relay_read_ms": device_api_split["host_publish_to_relay_read_ms"],
                "relay_read_to_network_send_begin_ms": device_api_split["relay_read_to_network_send_begin_ms"],
                "network_send_begin_to_stream_visible_ms": device_api_split["network_send_begin_to_stream_visible_ms"],
                "frame_publish_to_visible_ms": frame_publish_to_visible_ms,
                "host_publish_to_client_visible_ms": frame_publish_to_visible_ms,
                "event_to_visible_ms": ms_between(begin_ns, visible_ns),
                "visible_latency_ms": ms_between(begin_ns, visible_ns),
            }
            measurement.update(visible_meta)
            measurements.append(measurement)
            # Return after the measurement, not inside it: a user's Enter is its own request, and letting
            # `cat` echo the completed line keeps the next sample's token a fresh same-shape delta instead
            # of one progressively wrapping line.
            send_return_key(session_id, mobile_client_id, terminal_target)
            wait_for_line(stream, lambda payload, token=token: plain_text(payload).count(token) >= 2, timeout=10)
    finally:
        if stream is not None:
            close_stream(stream)
    return {
        "session_id": session_id,
        "terminal_target": terminal_target,
        "measurements": measurements,
        "summary": summarize_latencies(measurements),
        "phase_summaries": summarize_phases(measurements),
        "visible_render_summary": summarize_visible_render_samples(measurements),
        "budget_enforced": True,
    }


def run_ios_scrollback_latency(terminal_target: str) -> dict:
    scenario = "ios-scrollback-latency"
    title = f"{scenario}-{network_profile}-{terminal_target}-{uuid.uuid4().hex[:8]}"
    command = (
        "/usr/bin/python3 -c 'import time\n"
        "for i in range(1600): print(f\"SCROLLLINE {i:04d}\", flush=True)\n"
        "print(\"SCROLL_READY\", flush=True)\n"
        "time.sleep(300)'"
    )
    session_id = start_terminal(title, command, terminal_target)
    _, mobile_client_id, stream = attach_pair(session_id, terminal_target)
    latest_payload = latest_stream_payload(stream)
    ready_state = fetch_state(session_id, terminal_target)
    if "SCROLL_READY" not in plain_text(ready_state) and (latest_payload is None or "SCROLL_READY" not in plain_text(latest_payload[0])):
        wait_for_line(stream, lambda payload: "SCROLL_READY" in plain_text(payload), timeout=30)
    base_scroll_delta = float(os.environ.get("IOS_SCROLL_DELTA", "720"))
    remote_frame_timeout = float(os.environ.get("IOS_SCROLL_REMOTE_FRAME_TIMEOUT", "2"))
    measurements = []
    try:
        for index in range(sample_count):
            probe_id = f"ios-scroll-{index + 1:03d}-{uuid.uuid4().hex[:8]}"
            scroll_delta = base_scroll_delta if index % 2 == 0 else -base_scroll_delta
            before_state = fetch_state(session_id, terminal_target)
            before_text = plain_text(before_state)
            begin_ns = now_ns()
            event(
                "ios_scroll_begin",
                scenario,
                probe_id,
                begin_ns,
                network_profile=network_profile,
                terminal_target=terminal_target,
            )
            rpc_begin_ns = now_ns()
            event("ios_scroll_rpc_begin", scenario, probe_id, rpc_begin_ns)
            response, rpc_ms = send_scroll_request(session_id, mobile_client_id, scroll_delta, terminal_target)
            assert response["ok"], response
            rpc_end_ns = now_ns()
            event("ios_scroll_rpc_end", scenario, probe_id, rpc_end_ns, rpc_ms=ms_between(rpc_begin_ns, rpc_end_ns))
            direct_command = last_performance_event(
                session_id,
                "ios-direct-daemon",
                "direct_command_request",
                rpc_begin_ns,
                before_ns=rpc_end_ns,
                require_render_payload=False,
            )
            try:
                remote_frame = wait_for_line(stream, lambda payload, before_text=before_text: plain_text(payload) not in ("", before_text), timeout=remote_frame_timeout)
            except TimeoutError:
                remote_frame = None
            rendered_change_latency_ms = None
            rpc_end_to_render_visible_ms = None
            event_to_frame_publish_ms = None
            frame_publish_to_visible_ms = None
            no_op = remote_frame is None
            visible_meta = {}
            if remote_frame:
                changed_state, frame_ns = remote_frame
                visible_meta = visible_render_metadata(changed_state)
                rendered_change_latency_ms = ms_between(begin_ns, frame_ns)
                rpc_end_to_render_visible_ms = ms_between(rpc_end_ns, frame_ns)
                frame_publish = last_performance_event(session_id, "mac-host", "render_frame_payload_publish", begin_ns, before_ns=frame_ns)
                frame_publish_ns = frame_publish[1] if frame_publish else None
                event_to_frame_publish_ms = ms_between(begin_ns, frame_publish_ns) if frame_publish_ns is not None else None
                frame_publish_to_visible_ms = ms_between(frame_publish_ns, frame_ns) if frame_publish_ns is not None else None
                device_api_split = device_api_latency_split(session_id, begin_ns, frame_publish_ns, frame_ns)
                if frame_publish_ns is not None:
                    event(
                        "ios_scroll_frame_published",
                        scenario,
                        probe_id,
                        frame_publish_ns,
                        event_to_frame_publish_ms=event_to_frame_publish_ms,
                        frame_publish_to_visible_ms=frame_publish_to_visible_ms,
                        target_revision=(frame_publish[0].get("attributes") or {}).get("target_revision"),
                    )
                event(
                    "ios_scroll_rendered_change",
                    scenario,
                    probe_id,
                    frame_ns,
                    scroll_vertical=scroll_delta,
                    received=True,
                    text_changed=plain_text(changed_state) != before_text,
                    event_to_visible_ms=rendered_change_latency_ms,
                    rpc_end_to_render_visible_ms=rpc_end_to_render_visible_ms,
                    visible_reason=visible_meta["visible_reason"],
                    visible_frame_kind=visible_meta["visible_frame_kind"],
                    visible_fallback_reason=visible_meta["visible_fallback_reason"],
                    visible_changed_cell_count=visible_meta["visible_changed_cell_count"],
                    visible_render_update_bytes=visible_meta["visible_render_update_bytes"],
                    visible_json_payload_bytes=visible_meta["visible_json_payload_bytes"],
                )
            else:
                device_api_split = {
                    "host_publish_to_relay_read_ms": None,
                    "relay_read_to_network_send_begin_ms": None,
                    "network_send_begin_to_stream_visible_ms": None,
                }
                event(
                    "ios_scroll_noop",
                    scenario,
                    probe_id,
                    now_ns(),
                    scroll_vertical=scroll_delta,
                    received=False,
                    remote_frame_timeout_s=remote_frame_timeout,
                )
            measurement = {
                "sample_index": index + 1,
                "probe_id": probe_id,
                "scroll_delta": scroll_delta,
                "event_to_visible_ms": rendered_change_latency_ms,
                "visible_latency_ms": rendered_change_latency_ms,
                "rpc_end_to_render_visible_ms": rpc_end_to_render_visible_ms,
                "event_to_frame_publish_ms": event_to_frame_publish_ms,
                "event_to_host_publish_ms": event_to_frame_publish_ms,
                "host_publish_to_relay_read_ms": device_api_split["host_publish_to_relay_read_ms"],
                "relay_read_to_network_send_begin_ms": device_api_split["relay_read_to_network_send_begin_ms"],
                "network_send_begin_to_stream_visible_ms": device_api_split["network_send_begin_to_stream_visible_ms"],
                "frame_publish_to_visible_ms": frame_publish_to_visible_ms,
                "host_publish_to_client_visible_ms": frame_publish_to_visible_ms,
                "rendered_change_latency_ms": rendered_change_latency_ms,
                "rpc_ms": round(rpc_ms, 3),
                "direct_command_request_ms": (direct_command[0].get("elapsedMS") if direct_command else None),
                "direct_command_connection_reused": ((direct_command[0].get("attributes") or {}).get("connection_reused") if direct_command else None),
                "scroll_vertical": scroll_delta,
                "no_op": no_op,
            }
            if visible_meta:
                measurement.update(visible_meta)
            measurements.append(measurement)
    finally:
        if stream is not None:
            close_stream(stream)
    return {
        "session_id": session_id,
        "terminal_target": terminal_target,
        "measurements": measurements,
        "summary": summarize_latencies(measurements),
        "phase_summaries": summarize_phases(measurements),
        "visible_render_summary": summarize_visible_render_samples(measurements),
        "no_op_gestures": sum(1 for item in measurements if item.get("no_op")),
        "rendered_change_count": sum(1 for item in measurements if not item.get("no_op")),
        "budget_enforced": True,
    }


def payload_rate_summary(records: list[dict]) -> dict:
    good_records = [record for record in records if not record.get("decode_failed")]
    if not good_records:
        return {
            "bytes_per_second": 0,
            "peak_1s_bytes_per_second": 0,
            "peak_10s_bytes_per_second": 0,
            "decode_failures": decode_failures,
            "stale_drops": 0,
            "render_mode": "ghostty-mirror",
            "render_update_count": 0,
            "full_render_update_count": 0,
            "delta_render_update_count": 0,
            "materialized_snapshot_count": 0,
            "render_update_bytes": 0,
            "render_cadence_ms": summarize_values([]),
        }
    first_ns = good_records[0]["received_ns"]
    last_ns = good_records[-1]["received_ns"]
    total_bytes = sum(record["bytes"] for record in good_records)
    duration = max((last_ns - first_ns) / 1_000_000_000, 0.001)

    def peak(window_seconds: float) -> int:
        window_ns = int(window_seconds * 1_000_000_000)
        peak_bytes = 0
        left = 0
        running = 0
        for right, record in enumerate(good_records):
            running += record["bytes"]
            while record["received_ns"] - good_records[left]["received_ns"] > window_ns:
                running -= good_records[left]["bytes"]
                left += 1
            peak_bytes = max(peak_bytes, running)
        return int(peak_bytes / window_seconds)

    snapshot_records = [record for record in good_records if record.get("materialized_snapshot")]
    update_records = [record for record in good_records if record.get("render_update")]
    snapshot_intervals_ms = [
        round((snapshot_records[index]["received_ns"] - snapshot_records[index - 1]["received_ns"]) / 1_000_000, 3)
        for index in range(1, len(snapshot_records))
    ]

    return {
        "bytes_per_second": round(total_bytes / duration, 1),
        "peak_1s_bytes_per_second": peak(1),
        "peak_10s_bytes_per_second": peak(10),
        "decode_failures": decode_failures,
        "stale_drops": 0,
        "render_mode": "ghostty-mirror",
        "render_update_count": len(update_records),
        "full_render_update_count": sum(1 for record in update_records if record.get("frame_kind") == "full"),
        "delta_render_update_count": sum(1 for record in update_records if record.get("frame_kind") == "delta"),
        "materialized_snapshot_count": len(snapshot_records),
        "render_update_bytes": sum(record.get("render_update_bytes") or 0 for record in good_records),
        "render_cadence_ms": summarize_values(snapshot_intervals_ms),
    }


scenario_results: dict[str, dict] = {}
for terminal_target in terminal_targets:
    if terminal_target != "local":
        raise RuntimeError(f"unsupported terminal target: {terminal_target}; remote terminal latency runs in the paired-device E2E harness")
    for scenario in scenarios:
        result_key = f"{scenario}:{terminal_target}"
        scenario_started_ns = now_ns()
        if scenario == "ios-input-latency":
            scenario_results[result_key] = run_ios_input_latency(terminal_target)
        elif scenario == "ios-scrollback-latency":
            scenario_results[result_key] = run_ios_scrollback_latency(terminal_target)
        else:
            raise RuntimeError(f"unknown scenario: {scenario}")
        scenario_results[result_key]["duration_ms"] = ms_between(scenario_started_ns, now_ns())

payload_metrics = payload_rate_summary(stream_records)
failures = []
for result_key, result in scenario_results.items():
    name = result_key.split(":", 1)[0]
    terminal_target = result.get("terminal_target", "local")
    budget = budgets[(name, network_profile, terminal_target)]
    p95 = result["summary"]["p95_ms"]
    if result.get("budget_enforced", True):
        # An enforced budget with no samples is a harness failure, not a pass: a p95 of None means
        # the metric stopped resolving (or every gesture was a no-op), which is exactly the state a
        # regression gate must not report as success.
        if p95 is None:
            failures.append(f"{name} {network_profile} {terminal_target} collected no latency samples for an enforced budget")
        elif p95 > budget["gross_p95_ms"]:
            failures.append(
                f"{name} {network_profile} {terminal_target} p95 {p95}ms exceeded gross budget {budget['gross_p95_ms']}ms"
            )
for result_key, input_result in scenario_results.items():
    if not result_key.startswith("ios-input-latency:"):
        continue
    if input_result.get("terminal_target") != "local":
        continue
    for measurement in input_result.get("measurements") or []:
        sample_index = measurement.get("sample_index")
        frame_kind = measurement.get("visible_frame_kind")
        fallback_reason = measurement.get("visible_fallback_reason")
        if frame_kind != "delta":
            failures.append(f"{result_key} sample {sample_index} visible echo used {frame_kind or 'missing'} frame, expected delta")
        if fallback_reason == "explicit_resync":
            failures.append(f"{result_key} sample {sample_index} visible echo used explicit_resync")
if payload_metrics["decode_failures"] != 0:
    failures.append(f"render-update stream had {payload_metrics['decode_failures']} decode failures")
if payload_metrics["render_mode"] != "ghostty-mirror":
    failures.append(f"render mode was {payload_metrics['render_mode']}, expected ghostty-mirror")

payload = {
    "suite": "mobile-terminal-latency",
    "network_profile": network_profile,
    "network": {
        "profile": network_profile,
        "device_api_rtt_ms": network_rtt_ms,
        "remote_rtt_ms": remote_rtt_ms,
        "bandwidth_bps": network_bandwidth_bps,
        "chunk_bytes": network_chunk_bytes,
    },
    "terminal_targets": terminal_targets,
    "scenarios": scenario_results,
    "events": events,
    "render_metrics": payload_metrics,
    "budgets": {f"{name}:{profile}:{target}": value for (name, profile, target), value in budgets.items()},
    "report_only": report_only,
    "failures": failures,
}
summary_json.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")

print(f"terminal latency summary: {summary_json}")
for result_key, result in scenario_results.items():
    name = result_key.split(":", 1)[0]
    terminal_target = result.get("terminal_target", "local")
    budget = budgets[(name, network_profile, terminal_target)]
    summary = result["summary"]
    target = budget["target_p95_ms"]
    target_text = f", target p95 {target}ms" if target is not None else ""
    enforcement_text = "gross" if result.get("budget_enforced", True) else "report-only"
    rtt_label = f"remote_rtt={remote_rtt_ms:.3f}ms" if terminal_target == "remote" and remote_rtt_ms is not None else f"device_api_rtt={network_rtt_ms}ms"
    print(
        f"{name} [{network_profile}, terminal={terminal_target}, {rtt_label}]: "
        f"p50={summary['p50_ms']}ms p95={summary['p95_ms']}ms "
        f"max={summary['max_ms']}ms ({enforcement_text} {budget['gross_p95_ms']}ms{target_text})"
    )
    phases = result.get("phase_summaries") or {}
    if phases:
        print(
            "  phases: "
            f"enqueue_to_rpc_begin p95={format_ms(phases['enqueue_to_rpc_begin']['p95_ms'])}, "
            f"rpc p95={format_ms(phases['rpc_duration']['p95_ms'])}, "
            f"direct_command p95={format_ms(phases['direct_command_request']['p95_ms'])}, "
            f"event_to_frame_publish p95={format_ms(phases['event_to_frame_publish']['p95_ms'])}, "
            f"event_to_host_publish p95={format_ms(phases['event_to_host_publish']['p95_ms'])}, "
            f"host_publish_to_relay_read p95={format_ms(phases['host_publish_to_relay_read']['p95_ms'])}, "
            f"relay_read_to_send_begin p95={format_ms(phases['relay_read_to_network_send_begin']['p95_ms'])}, "
            f"send_begin_to_stream_visible p95={format_ms(phases['network_send_begin_to_stream_visible']['p95_ms'])}, "
            f"frame_publish_to_visible p95={format_ms(phases['frame_publish_to_visible']['p95_ms'])}, "
            f"host_publish_to_client_visible p95={format_ms(phases['host_publish_to_client_visible']['p95_ms'])}, "
            f"rpc_end_to_visible p95={format_ms(phases['rpc_end_to_render_visible']['p95_ms'])}, "
            f"event_to_visible p95={format_ms(phases['event_to_visible_total']['p95_ms'])}"
        )
    if result.get("measurements"):
        print(f"  samples: {sample_series(result['measurements'])}")
    visible_render = result.get("visible_render_summary") or {}
    if visible_render:
        print(
            "  visible render: "
            f"full={visible_render.get('full_visible_sample_count', 0)} "
            f"delta={visible_render.get('delta_visible_sample_count', 0)} "
            f"resync_required={visible_render.get('resync_required_visible_sample_count', 0)} "
            f"median_update_bytes={visible_render.get('median_visible_render_update_bytes')}"
        )
    if "no_op_gestures" in result:
        print(f"  scroll movement: rendered_changes={result['rendered_change_count']} no_ops={result['no_op_gestures']}")
print(
    "render payload: "
    f"avg={payload_metrics['bytes_per_second']} B/s "
    f"peak1s={payload_metrics['peak_1s_bytes_per_second']} B/s "
    f"peak10s={payload_metrics['peak_10s_bytes_per_second']} B/s "
    f"decode_failures={payload_metrics['decode_failures']} "
    f"render_updates={payload_metrics['render_update_count']} "
    f"full={payload_metrics['full_render_update_count']} "
    f"delta={payload_metrics['delta_render_update_count']} "
    f"materialized_snapshots={payload_metrics['materialized_snapshot_count']}"
)
if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    if not report_only:
        raise SystemExit(1)
PY
