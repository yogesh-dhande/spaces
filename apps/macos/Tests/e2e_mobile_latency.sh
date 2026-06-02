#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
source "$SCRIPT_DIR/terminal_harness_lock.sh"

SPACES_CLI="${SPACES_CLI:-$APP_ROOT/.build/debug/spaces}"
TERMINAL_SERVICE="${SPACES_TERMINAL_SERVICE_EXECUTABLE:-$APP_ROOT/.build/debug/SpacesTerminalService}"
WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-mobile-latency.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/runtime}"
SERVICE_LOG="$WORK_ROOT/terminal-service.log"
BRIDGE_LOG="$WORK_ROOT/mobile-bridge.log"
PERF_JSONL="$WORK_ROOT/mobile-terminal-performance.jsonl"
SUMMARY_JSON="$WORK_ROOT/terminal-latency-summary.json"
SAMPLES="${SAMPLES:-12}"
NETWORK_PROFILE="local"
KEEP_ROOT="${KEEP_ROOT:-0}"

SCENARIOS=(ios-input-latency ios-scrollback-latency)
SELECTED_SCENARIOS=()
SERVICE_PID=""
BRIDGE_PID=""

print_usage() {
  cat <<'EOF'
Usage: apps/macos/Tests/e2e_mobile_latency.sh [options]

Options:
  --list                    List available scenarios.
  --scenario NAME           Run only one scenario. May be passed multiple times.
  --network-profile NAME    local or ios-constrained. Defaults to local.
  --samples N               Probe count per scenario. Defaults to 12.
  --keep-root               Preserve the temporary profile root.
  --help                    Show this help text.

Network profile defaults:
  local             No bridge shaping.
  ios-constrained   80ms RTT, 8Mbps, 16KB chunks.

Env overrides:
  SPACES_MOBILE_BRIDGE_NETWORK_RTT_MS
  SPACES_MOBILE_BRIDGE_NETWORK_BANDWIDTH_BPS
  SPACES_MOBILE_BRIDGE_NETWORK_CHUNK_BYTES
EOF
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  KEEP_ROOT=1
  if [[ -f "$SERVICE_LOG" ]]; then
    printf '\nTerminal service log tail:\n' >&2
    tail -n 160 "$SERVICE_LOG" >&2 || true
  fi
  if [[ -f "$BRIDGE_LOG" ]]; then
    printf '\nMobile bridge log tail:\n' >&2
    tail -n 160 "$BRIDGE_LOG" >&2 || true
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
  if [[ -n "$BRIDGE_PID" ]]; then
    kill "$BRIDGE_PID" >/dev/null 2>&1 || true
    wait "$BRIDGE_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$SERVICE_PID" ]]; then
    kill "$SERVICE_PID" >/dev/null 2>&1 || true
    wait "$SERVICE_PID" >/dev/null 2>&1 || true
  fi
  stop_terminal_service_for_runtime_dir "$RUNTIME_DIR" 5
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
[[ -x "$SPACES_CLI" ]] || fail "spaces CLI not found at $SPACES_CLI"
[[ -x "$TERMINAL_SERVICE" ]] || fail "SpacesTerminalService not found at $TERMINAL_SERVICE"

mkdir -p "$(dirname "$DB_PATH")" "$RUNTIME_DIR"
touch "$PERF_JSONL"
export SPACES_DB_PATH="$DB_PATH"
export SPACES_RUNTIME_DIR="$RUNTIME_DIR"
export SPACES_TERMINAL_SERVICE_EXECUTABLE="$TERMINAL_SERVICE"
export SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH="$PERF_JSONL"

"$TERMINAL_SERVICE" >"$SERVICE_LOG" 2>&1 &
SERVICE_PID="$!"

service_socket="$(terminal_service_socket_path_for_runtime_dir "$RUNTIME_DIR")"
service_deadline=$((SECONDS + 15))
while [[ $SECONDS -lt $service_deadline ]]; do
  [[ -S "$service_socket" ]] && break
  sleep 0.1
done
[[ -S "$service_socket" ]] || fail "timed out waiting for terminal service socket"

bridge_env=(SPACES_MOBILE_BRIDGE_NETWORK_PROFILE="$NETWORK_PROFILE")
if [[ "$NETWORK_PROFILE" == "ios-constrained" ]]; then
  bridge_env+=(
    SPACES_MOBILE_BRIDGE_NETWORK_RTT_MS="${SPACES_MOBILE_BRIDGE_NETWORK_RTT_MS:-80}"
    SPACES_MOBILE_BRIDGE_NETWORK_BANDWIDTH_BPS="${SPACES_MOBILE_BRIDGE_NETWORK_BANDWIDTH_BPS:-8000000}"
    SPACES_MOBILE_BRIDGE_NETWORK_CHUNK_BYTES="${SPACES_MOBILE_BRIDGE_NETWORK_CHUNK_BYTES:-16384}"
  )
fi

env "${bridge_env[@]}" "$SPACES_CLI" mobile serve --host 127.0.0.1 --port 0 >"$BRIDGE_LOG" 2>&1 &
BRIDGE_PID="$!"

ready_deadline=$((SECONDS + 15))
while [[ $SECONDS -lt $ready_deadline ]]; do
  grep -q 'Spaces mobile bridge ready' "$BRIDGE_LOG" 2>/dev/null && break
  sleep 0.1
done
grep -q 'Spaces mobile bridge ready' "$BRIDGE_LOG" || fail "timed out waiting for mobile bridge readiness"

parsed_bridge="$(
python3 - "$BRIDGE_LOG" <<'PY'
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
print(f"BRIDGE_PORT={shlex.quote(port_match.group(1))}")
print(f"PAIRING_LINK={shlex.quote(link)}")
print(f"TRANSPORT_KEY={shlex.quote(values['psk'][0])}")
print(f"PAIRING_CODE={shlex.quote(values['code'][0])}")
print(f"PAIRING_NONCE={shlex.quote(values['nonce'][0])}")
PY
)"
eval "$parsed_bridge"

BRIDGE_PORT="$BRIDGE_PORT" \
PAIRING_LINK="$PAIRING_LINK" \
TRANSPORT_KEY="$TRANSPORT_KEY" \
PAIRING_CODE="$PAIRING_CODE" \
PAIRING_NONCE="$PAIRING_NONCE" \
NETWORK_PROFILE="$NETWORK_PROFILE" \
SAMPLES="$SAMPLES" \
SUMMARY_JSON="$SUMMARY_JSON" \
PERFORMANCE_LOG_PATH="$PERF_JSONL" \
WORK_ROOT="$WORK_ROOT" \
SPACES_CLI="$SPACES_CLI" \
python3 - "${SELECTED_SCENARIOS[@]}" <<'PY'
import base64
import json
import math
import os
import re
import select
import statistics
import subprocess
import sys
import time
import uuid
from pathlib import Path

scenarios = sys.argv[1:]
host = "127.0.0.1"
port = int(os.environ["BRIDGE_PORT"])
transport_key = os.environ["TRANSPORT_KEY"]
pairing_code = os.environ["PAIRING_CODE"]
pairing_nonce = os.environ["PAIRING_NONCE"]
network_profile = os.environ["NETWORK_PROFILE"]
sample_count = int(os.environ["SAMPLES"])
summary_json = Path(os.environ["SUMMARY_JSON"])
performance_log_path = Path(os.environ["PERFORMANCE_LOG_PATH"])
work_root = Path(os.environ["WORK_ROOT"])
spaces_cli = os.environ["SPACES_CLI"]
base_env = os.environ.copy()

events: list[dict] = []
stream_records: list[dict] = []
decode_failures = 0

budgets = {
    ("ios-input-latency", "local"): {"gross_p95_ms": 1000, "target_p95_ms": 150},
    ("ios-scrollback-latency", "local"): {"gross_p95_ms": 750, "target_p95_ms": 100},
    ("ios-input-latency", "ios-constrained"): {"gross_p95_ms": 3000, "target_p95_ms": 600},
    ("ios-scrollback-latency", "ios-constrained"): {"gross_p95_ms": 2500, "target_p95_ms": None},
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
    require_render_frame: bool = True,
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
            candidates.append((emitted_ns, record))
        if candidates:
            emitted_ns, record = max(candidates, key=lambda item: item[0])
            return record, emitted_ns
        time.sleep(0.02)
    return None


def extract_session_id(output: str) -> str:
    match = re.findall(r"[0-9A-Fa-f-]{36}", output)
    if not match:
        raise RuntimeError(f"failed to parse session id from: {output}")
    return match[-1].upper()


def wait_for_session_id_by_title(title: str, timeout: float = 10) -> str:
    sessions_root = Path(os.environ["SPACES_RUNTIME_DIR"]) / "terminal" / "sessions"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for metadata_path in sessions_root.glob("*/metadata.json"):
            try:
                metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if metadata.get("title") != title:
                continue
            session_id = metadata.get("sessionID") or metadata_path.parent.name
            if (metadata_path.parent / "control.sock").exists() or (metadata_path.parent / "state.json").exists():
                return session_id.upper()
        time.sleep(0.1)
    raise TimeoutError(f"timed out recovering session id for title {title}")


def start_terminal(title: str, command: str) -> str:
    try:
        completed = run(
            [spaces_cli, "terminal", "command", "--backend", "ghostty-embedded", "--command", command, "--title", title],
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


def request(payload: dict) -> tuple[dict, float]:
    started = time.perf_counter()
    completed = run(
        [
            spaces_cli,
            "mobile",
            "request",
            "--host",
            host,
            "--port",
            str(port),
            "--transport-key",
            transport_key,
            "--request-json",
            json.dumps(payload),
        ],
        timeout=20,
    )
    return json.loads(completed.stdout), (time.perf_counter() - started) * 1000


def connect_stream(payload: dict) -> subprocess.Popen:
    return subprocess.Popen(
        [
            spaces_cli,
            "mobile",
            "request",
            "--host",
            host,
            "--port",
            str(port),
            "--transport-key",
            transport_key,
            "--request-json",
            json.dumps(payload),
            "--stream",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=base_env,
    )


def decode_frame(payload: dict) -> dict | None:
    encoded = payload.get("renderFrame")
    if not encoded:
        return None
    try:
        return json.loads(base64.b64decode(encoded))
    except Exception:
        return None


def plain_text(payload: dict) -> str:
    frame = decode_frame(payload)
    if not frame:
        return ""
    snapshot = frame.get("snapshot") or {}
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
    global decode_failures
    assert stream.stdout is not None
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([stream.stdout], [], [], max(0.0, deadline - time.monotonic()))
        if not ready:
            continue
        line = stream.stdout.readline()
        if not line:
            break
        received_ns = now_ns()
        line_bytes = len(line.encode("utf-8"))
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            decode_failures += 1
            stream_records.append({"received_ns": received_ns, "bytes": line_bytes, "decode_failed": True})
            continue
        stream_records.append(
            {
                "received_ns": received_ns,
                "bytes": line_bytes,
                "decode_failed": False,
                "reason": payload.get("reason"),
                "render_frame": bool(payload.get("renderFrame")),
                "render_frame_bytes": len((payload.get("renderFrame") or "").encode("utf-8")),
            }
        )
        if predicate(payload):
            return payload, received_ns
    raise TimeoutError("timed out waiting for streamed terminal state")


client_app = {
    "installationID": str(uuid.uuid4()).upper(),
    "bundleID": "com.yogeshdhande.spacesmobile",
    "platform": "ios",
    "deviceName": "iPhone Latency Harness",
    "appVersion": "1.0",
}

pair_response, _ = request(
    {
        "command": "pair",
        "pairingCode": pairing_code,
        "pairingNonce": pairing_nonce,
        "clientApp": client_app,
    }
)
assert pair_response["ok"], pair_response
auth_token = pair_response["issuedAuthToken"]


def attach_pair(session_id: str) -> tuple[str, str, subprocess.Popen]:
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
        }
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
        }
    )
    assert response["ok"], response
    stream = connect_stream(
        {
            "command": "subscribe",
            "authToken": auth_token,
            "clientApp": client_app,
            "sessionID": session_id,
            "clientID": mobile_client_id,
        }
    )
    wait_for_line(stream, lambda payload: payload.get("sessionID") == session_id, timeout=10)
    def owner_is_mobile(payload: dict) -> bool:
        snapshot = payload.get("attachmentSnapshot") or {}
        return any(
            attachment.get("mode") == "owner"
            and attachment.get("detachedAt") is None
            and attachment.get("clientID") == mobile_client_id
            for attachment in snapshot.get("attachments") or []
        )

    try:
        response, _ = request(
            {
                "command": "takeover",
                "authToken": auth_token,
                "clientApp": client_app,
                "sessionID": session_id,
                "clientID": mobile_client_id,
            }
        )
        assert response["ok"], response
    except subprocess.CalledProcessError:
        pass

    wait_for_line(stream, owner_is_mobile, timeout=10)
    return desktop_client_id, mobile_client_id, stream


def fetch_state(session_id: str) -> dict:
    response, _ = request(
        {
            "command": "state",
            "authToken": auth_token,
            "clientApp": client_app,
            "sessionID": session_id,
        }
    )
    assert response["ok"], response
    return response["sessionState"]


def poll_state_contains(session_id: str, needle: str, timeout: float = 10) -> tuple[dict, int]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = fetch_state(session_id)
        if state.get("renderFrame") and needle in plain_text(state):
            return state, now_ns()
        time.sleep(0.1)
    raise TimeoutError(f"timed out waiting for terminal state containing {needle!r}")


def poll_state_text_change(session_id: str, before_text: str, timeout: float = 10) -> tuple[dict, int]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = fetch_state(session_id)
        text = plain_text(state)
        if state.get("renderFrame") and text and text != before_text:
            return state, now_ns()
        time.sleep(0.1)
    raise TimeoutError("timed out waiting for terminal state text change")


def optional_state_text_change(session_id: str, before_text: str, timeout: float = 2) -> tuple[dict, int] | None:
    try:
        return poll_state_text_change(session_id, before_text, timeout=timeout)
    except TimeoutError:
        return None


def send_scroll_request(session_id: str, mobile_client_id: str, scroll_vertical: float) -> tuple[dict, float]:
    return request(
        {
            "command": "scroll",
            "authToken": auth_token,
            "clientApp": client_app,
            "sessionID": session_id,
            "clientID": mobile_client_id,
            "scrollVertical": scroll_vertical,
        }
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
        "event_to_frame_publish": summarize_latencies(measurements, "event_to_frame_publish_ms"),
        "host_publish_to_relay_read": summarize_latencies(measurements, "host_publish_to_relay_read_ms"),
        "relay_read_to_network_send_begin": summarize_latencies(measurements, "relay_read_to_network_send_begin_ms"),
        "network_send_begin_to_stream_visible": summarize_latencies(measurements, "network_send_begin_to_stream_visible_ms"),
        "frame_publish_to_visible": summarize_latencies(measurements, "frame_publish_to_visible_ms"),
        "rpc_end_to_render_visible": summarize_latencies(measurements, "rpc_end_to_render_visible_ms"),
        "event_to_visible_total": summarize_latencies(measurements, "event_to_visible_ms"),
    }


def bridge_latency_split(session_id: str, begin_ns: int, frame_publish_ns: int | None, visible_ns: int) -> dict:
    after_ns = frame_publish_ns if frame_publish_ns is not None else begin_ns
    relay_read = last_performance_event(session_id, "mobile-bridge", "stream_relay_read", after_ns, before_ns=visible_ns)
    relay_read_ns = relay_read[1] if relay_read else None
    network_send_begin = last_performance_event(
        session_id,
        "mobile-bridge",
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


def run_ios_input_latency() -> dict:
    scenario = "ios-input-latency"
    title = f"{scenario}-{network_profile}-{uuid.uuid4().hex[:8]}"
    session_id = start_terminal(title, "cat")
    _, mobile_client_id, stream = attach_pair(session_id)
    measurements = []
    try:
        for index in range(sample_count):
            probe_id = f"ios-input-{index + 1:03d}-{uuid.uuid4().hex[:8]}"
            token = f"ioslatency{index + 1:03d}{uuid.uuid4().hex[:6]}"
            begin_ns = now_ns()
            event("ios_input_begin", scenario, probe_id, begin_ns, token=token, network_profile=network_profile)
            enqueue_ns = now_ns()
            event("ios_input_enqueue", scenario, probe_id, enqueue_ns)
            flush_ns = now_ns()
            event("ios_input_flush", scenario, probe_id, flush_ns)
            rpc_begin_ns = now_ns()
            event("ios_input_rpc_begin", scenario, probe_id, rpc_begin_ns, enqueue_to_rpc_begin_ms=ms_between(enqueue_ns, rpc_begin_ns))
            response, rpc_ms = request(
                {
                    "command": "send",
                    "authToken": auth_token,
                    "clientApp": client_app,
                    "sessionID": session_id,
                    "clientID": mobile_client_id,
                    "text": token,
                    "appendNewline": True,
                }
            )
            assert response["ok"], response
            rpc_end_ns = now_ns()
            rpc_duration_ms = ms_between(rpc_begin_ns, rpc_end_ns)
            event("ios_input_rpc_end", scenario, probe_id, rpc_end_ns, rpc_ms=rpc_duration_ms)
            _, visible_ns = wait_for_line(stream, lambda payload, token=token: token in plain_text(payload), timeout=10)
            frame_publish = last_performance_event(session_id, "mac-host", "render_frame_payload_publish", begin_ns, before_ns=visible_ns)
            frame_publish_ns = frame_publish[1] if frame_publish else None
            event_to_frame_publish_ms = ms_between(begin_ns, frame_publish_ns) if frame_publish_ns is not None else None
            frame_publish_to_visible_ms = ms_between(frame_publish_ns, visible_ns) if frame_publish_ns is not None else None
            bridge_split = bridge_latency_split(session_id, begin_ns, frame_publish_ns, visible_ns)
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
            )
            measurements.append(
                {
                    "sample_index": index + 1,
                    "probe_id": probe_id,
                    "token": token,
                    "enqueue_to_rpc_begin_ms": ms_between(enqueue_ns, rpc_begin_ns),
                    "flush_to_rpc_begin_ms": ms_between(flush_ns, rpc_begin_ns),
                    "rpc_ms": round(rpc_ms, 3),
                    "rpc_end_to_render_visible_ms": ms_between(rpc_end_ns, visible_ns),
                    "event_to_frame_publish_ms": event_to_frame_publish_ms,
                    "host_publish_to_relay_read_ms": bridge_split["host_publish_to_relay_read_ms"],
                    "relay_read_to_network_send_begin_ms": bridge_split["relay_read_to_network_send_begin_ms"],
                    "network_send_begin_to_stream_visible_ms": bridge_split["network_send_begin_to_stream_visible_ms"],
                    "frame_publish_to_visible_ms": frame_publish_to_visible_ms,
                    "event_to_visible_ms": ms_between(begin_ns, visible_ns),
                    "visible_latency_ms": ms_between(begin_ns, visible_ns),
                }
            )
    finally:
        close_stream(stream)
    return {
        "session_id": session_id,
        "measurements": measurements,
        "summary": summarize_latencies(measurements),
        "phase_summaries": summarize_phases(measurements),
        "budget_enforced": True,
    }


def run_ios_scrollback_latency() -> dict:
    scenario = "ios-scrollback-latency"
    title = f"{scenario}-{network_profile}-{uuid.uuid4().hex[:8]}"
    command = (
        "/usr/bin/python3 -c 'import time\n"
        "for i in range(1600): print(f\"SCROLLLINE {i:04d}\", flush=True)\n"
        "print(\"SCROLL_READY\", flush=True)\n"
        "time.sleep(300)'"
    )
    session_id = start_terminal(title, command)
    _, mobile_client_id, stream = attach_pair(session_id)
    poll_state_contains(session_id, "SCROLL_READY", timeout=30)
    base_scroll_delta = float(os.environ.get("IOS_SCROLL_DELTA", "720"))
    remote_frame_timeout = float(os.environ.get("IOS_SCROLL_REMOTE_FRAME_TIMEOUT", "2"))
    measurements = []
    try:
        for index in range(sample_count):
            probe_id = f"ios-scroll-{index + 1:03d}-{uuid.uuid4().hex[:8]}"
            scroll_delta = base_scroll_delta if index % 2 == 0 else -base_scroll_delta
            before_state = fetch_state(session_id)
            before_text = plain_text(before_state)
            begin_ns = now_ns()
            event("ios_scroll_begin", scenario, probe_id, begin_ns, network_profile=network_profile)
            rpc_begin_ns = now_ns()
            event("ios_scroll_rpc_begin", scenario, probe_id, rpc_begin_ns)
            response, rpc_ms = send_scroll_request(session_id, mobile_client_id, scroll_delta)
            assert response["ok"], response
            rpc_end_ns = now_ns()
            event("ios_scroll_rpc_end", scenario, probe_id, rpc_end_ns, rpc_ms=ms_between(rpc_begin_ns, rpc_end_ns))
            remote_frame = optional_state_text_change(session_id, before_text, timeout=remote_frame_timeout)
            rendered_change_latency_ms = None
            rpc_end_to_render_visible_ms = None
            event_to_frame_publish_ms = None
            frame_publish_to_visible_ms = None
            no_op = remote_frame is None
            if remote_frame:
                changed_state, frame_ns = remote_frame
                rendered_change_latency_ms = ms_between(begin_ns, frame_ns)
                rpc_end_to_render_visible_ms = ms_between(rpc_end_ns, frame_ns)
                frame_publish = last_performance_event(session_id, "mac-host", "render_frame_payload_publish", begin_ns, before_ns=frame_ns)
                frame_publish_ns = frame_publish[1] if frame_publish else None
                event_to_frame_publish_ms = ms_between(begin_ns, frame_publish_ns) if frame_publish_ns is not None else None
                frame_publish_to_visible_ms = ms_between(frame_publish_ns, frame_ns) if frame_publish_ns is not None else None
                bridge_split = bridge_latency_split(session_id, begin_ns, frame_publish_ns, frame_ns)
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
                )
            else:
                bridge_split = {
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
            measurements.append(
                {
                    "sample_index": index + 1,
                    "probe_id": probe_id,
                    "scroll_delta": scroll_delta,
                    "event_to_visible_ms": rendered_change_latency_ms,
                    "visible_latency_ms": rendered_change_latency_ms,
                    "rpc_end_to_render_visible_ms": rpc_end_to_render_visible_ms,
                    "event_to_frame_publish_ms": event_to_frame_publish_ms,
                    "host_publish_to_relay_read_ms": bridge_split["host_publish_to_relay_read_ms"],
                    "relay_read_to_network_send_begin_ms": bridge_split["relay_read_to_network_send_begin_ms"],
                    "network_send_begin_to_stream_visible_ms": bridge_split["network_send_begin_to_stream_visible_ms"],
                    "frame_publish_to_visible_ms": frame_publish_to_visible_ms,
                    "rendered_change_latency_ms": rendered_change_latency_ms,
                    "rpc_ms": round(rpc_ms, 3),
                    "scroll_vertical": scroll_delta,
                    "no_op": no_op,
                }
            )
    finally:
        close_stream(stream)
    return {
        "session_id": session_id,
        "measurements": measurements,
        "summary": summarize_latencies(measurements),
        "phase_summaries": summarize_phases(measurements),
        "no_op_gestures": sum(1 for item in measurements if item.get("no_op")),
        "rendered_change_count": sum(1 for item in measurements if not item.get("no_op")),
        "report_only": True,
        "budget_enforced": False,
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
            "render_frame_count": 0,
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

    frame_records = [record for record in good_records if record.get("render_frame")]
    frame_intervals_ms = [
        round((frame_records[index]["received_ns"] - frame_records[index - 1]["received_ns"]) / 1_000_000, 3)
        for index in range(1, len(frame_records))
    ]

    return {
        "bytes_per_second": round(total_bytes / duration, 1),
        "peak_1s_bytes_per_second": peak(1),
        "peak_10s_bytes_per_second": peak(10),
        "decode_failures": decode_failures,
        "stale_drops": 0,
        "render_mode": "ghostty-mirror",
        "render_frame_count": len(frame_records),
        "render_cadence_ms": summarize_values(frame_intervals_ms),
    }


scenario_results: dict[str, dict] = {}
for scenario in scenarios:
    if scenario == "ios-input-latency":
        scenario_results[scenario] = run_ios_input_latency()
    elif scenario == "ios-scrollback-latency":
        scenario_results[scenario] = run_ios_scrollback_latency()
    else:
        raise RuntimeError(f"unknown scenario: {scenario}")

payload_metrics = payload_rate_summary(stream_records)
failures = []
for name, result in scenario_results.items():
    budget = budgets[(name, network_profile)]
    p95 = result["summary"]["p95_ms"]
    if result.get("budget_enforced", True) and p95 is not None and p95 > budget["gross_p95_ms"]:
        failures.append(f"{name} {network_profile} p95 {p95}ms exceeded gross budget {budget['gross_p95_ms']}ms")
if payload_metrics["decode_failures"] != 0:
    failures.append(f"render-frame stream had {payload_metrics['decode_failures']} decode failures")
if payload_metrics["render_mode"] != "ghostty-mirror":
    failures.append(f"render mode was {payload_metrics['render_mode']}, expected ghostty-mirror")

payload = {
    "suite": "mobile-terminal-latency",
    "network_profile": network_profile,
    "scenarios": scenario_results,
    "events": events,
    "render_metrics": payload_metrics,
    "budgets": {f"{name}:{profile}": value for (name, profile), value in budgets.items()},
    "failures": failures,
}
summary_json.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")

print(f"terminal latency summary: {summary_json}")
for name, result in scenario_results.items():
    budget = budgets[(name, network_profile)]
    summary = result["summary"]
    target = budget["target_p95_ms"]
    target_text = f", target p95 {target}ms" if target is not None else ""
    enforcement_text = "gross" if result.get("budget_enforced", True) else "report-only"
    print(
        f"{name} [{network_profile}]: p50={summary['p50_ms']}ms p95={summary['p95_ms']}ms "
        f"max={summary['max_ms']}ms ({enforcement_text} {budget['gross_p95_ms']}ms{target_text})"
    )
    phases = result.get("phase_summaries") or {}
    if phases:
        print(
            "  phases: "
            f"enqueue_to_rpc_begin p95={format_ms(phases['enqueue_to_rpc_begin']['p95_ms'])}, "
            f"rpc p95={format_ms(phases['rpc_duration']['p95_ms'])}, "
            f"event_to_frame_publish p95={format_ms(phases['event_to_frame_publish']['p95_ms'])}, "
            f"host_publish_to_relay_read p95={format_ms(phases['host_publish_to_relay_read']['p95_ms'])}, "
            f"relay_read_to_send_begin p95={format_ms(phases['relay_read_to_network_send_begin']['p95_ms'])}, "
            f"send_begin_to_stream_visible p95={format_ms(phases['network_send_begin_to_stream_visible']['p95_ms'])}, "
            f"frame_publish_to_visible p95={format_ms(phases['frame_publish_to_visible']['p95_ms'])}, "
            f"rpc_end_to_visible p95={format_ms(phases['rpc_end_to_render_visible']['p95_ms'])}, "
            f"event_to_visible p95={format_ms(phases['event_to_visible_total']['p95_ms'])}"
        )
    if result.get("measurements"):
        print(f"  samples: {sample_series(result['measurements'])}")
    if "no_op_gestures" in result:
        print(f"  scroll movement: rendered_changes={result['rendered_change_count']} no_ops={result['no_op_gestures']}")
print(
    "render payload: "
    f"avg={payload_metrics['bytes_per_second']} B/s "
    f"peak1s={payload_metrics['peak_1s_bytes_per_second']} B/s "
    f"peak10s={payload_metrics['peak_10s_bytes_per_second']} B/s "
    f"decode_failures={payload_metrics['decode_failures']} "
    f"render_frames={payload_metrics['render_frame_count']}"
)
if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    raise SystemExit(1)
PY
