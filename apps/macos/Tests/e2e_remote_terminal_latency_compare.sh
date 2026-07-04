#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
source "$REPO_ROOT/scripts/spaces-e2e-env.sh"
spaces_e2e_require_remote_host_env "$REPO_ROOT"
source "$SCRIPT_DIR/terminal_harness_lock.sh"

SPACES_E2E="${SPACES_E2E:-$APP_ROOT/.build/debug/spacese2e}"
TERMINAL_SERVICE="${SPACESD_EXECUTABLE:-$APP_ROOT/.build/debug/spacesd}"
WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-remote-terminal-compare.XXXXXX")}"
SUMMARY_JSON="${SPACES_E2E_REMOTE_TERMINAL_COMPARE_SUMMARY_JSON:-$WORK_ROOT/remote-terminal-latency-compare-summary.json}"
REMOTE_DEVICE_RESULT_JSON="${SPACES_E2E_REMOTE_TERMINAL_COMPARE_DEVICE_JSON:-$WORK_ROOT/remote-device-result.json}"
REMOTE_DEVICE_LATENCY_JSON="$WORK_ROOT/remote-device-terminal-latency-summary.json"
LOCAL_DB_PATH="$WORK_ROOT/local/spaces.db"
LOCAL_RUNTIME_DIR="$WORK_ROOT/local/runtime"
LOCAL_HOME="$WORK_ROOT/local/home"
LOCAL_SERVICE_LOG="$WORK_ROOT/local-spacesd.log"
SAMPLES="${SAMPLES:-12}"
KEEP_ROOT="${KEEP_ROOT:-0}"
REMOTE_HOST="${SPACES_E2E_REMOTE_SSH_HOST:-}"
REMOTE_USER="${SPACES_E2E_REMOTE_SSH_USER:-}"
REMOTE_SSH_PORT="${SPACES_E2E_REMOTE_SSH_PORT:-}"

LOCAL_SERVICE_PID=""

print_usage() {
  cat <<'EOF'
Usage: apps/macos/Tests/e2e_remote_terminal_latency_compare.sh [options]

Options:
  --samples N        Probe count per target/scenario. Defaults to 12.
  --keep-root        Preserve the temporary profile root.
  --help             Show this help text.
EOF
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  KEEP_ROOT=1
  if [[ -f "$LOCAL_SERVICE_LOG" ]]; then
    printf '\nlocal spacesd log tail:\n' >&2
    tail -n 160 "$LOCAL_SERVICE_LOG" >&2 || true
  fi
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
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
}

cleanup() {
  local exit_code=$?
  if [[ -n "$LOCAL_SERVICE_PID" ]]; then
    kill "$LOCAL_SERVICE_PID" >/dev/null 2>&1 || true
    wait "$LOCAL_SERVICE_PID" >/dev/null 2>&1 || true
  fi
  stop_terminal_service_for_runtime_dir "$LOCAL_RUNTIME_DIR" 5
  release_terminal_harness_lock
  if [[ "$KEEP_ROOT" == "1" || $exit_code -ne 0 ]]; then
    printf 'Preserved remote terminal comparison root: %s\n' "$WORK_ROOT" >&2
  else
    rm -rf "$WORK_ROOT" || true
  fi
  return "$exit_code"
}
trap cleanup EXIT

parse_args "$@"
[[ "$SAMPLES" =~ ^[0-9]+$ && "$SAMPLES" -gt 0 ]] || fail "--samples must be a positive integer"
[[ -x "$SPACES_E2E" ]] || fail "spacese2e not found at $SPACES_E2E"
[[ -x "$TERMINAL_SERVICE" ]] || fail "spacesd not found at $TERMINAL_SERVICE"
[[ -n "$REMOTE_HOST" ]] || fail "SPACES_E2E_REMOTE_SSH_HOST is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v ssh >/dev/null 2>&1 || fail "ssh is required"

mkdir -p "$WORK_ROOT" "$LOCAL_HOME" "$LOCAL_RUNTIME_DIR" "$(dirname "$SUMMARY_JSON")"

printf '[remote-terminal-compare] preparing paired remote daemon\n'
SPACES_E2E_REMOTE_DEVICE_RESULT_JSON="$REMOTE_DEVICE_RESULT_JSON" \
SPACES_E2E_REMOTE_DEVICE_TERMINAL_LATENCY_JSON="$REMOTE_DEVICE_LATENCY_JSON" \
SPACES_E2E_REMOTE_DEVICE_TERMINAL_LATENCY_SAMPLES=1 \
KEEP_ROOT=1 \
"$SCRIPT_DIR/e2e_remote_device_api.sh" >/dev/null

printf '[remote-terminal-compare] starting local daemon for Spaces SSH baseline\n'
acquire_terminal_harness_lock
HOME="$LOCAL_HOME" \
SPACES_DB_PATH="$LOCAL_DB_PATH" \
SPACES_RUNTIME_DIR="$LOCAL_RUNTIME_DIR" \
"$TERMINAL_SERVICE" >"$LOCAL_SERVICE_LOG" 2>&1 &
LOCAL_SERVICE_PID="$!"

service_socket="$(terminal_service_socket_path_for_runtime_dir "$LOCAL_RUNTIME_DIR")"
deadline=$((SECONDS + 20))
while [[ $SECONDS -lt $deadline ]]; do
  [[ -S "$service_socket" ]] && break
  if ! kill -0 "$LOCAL_SERVICE_PID" >/dev/null 2>&1; then
    fail "local spacesd exited before opening its socket"
  fi
  sleep 0.1
done
[[ -S "$service_socket" ]] || fail "timed out waiting for local spacesd socket"

SPACES_E2E="$SPACES_E2E" \
LOCAL_DB_PATH="$LOCAL_DB_PATH" \
LOCAL_RUNTIME_DIR="$LOCAL_RUNTIME_DIR" \
REMOTE_DEVICE_RESULT_JSON="$REMOTE_DEVICE_RESULT_JSON" \
REMOTE_DEVICE_LATENCY_JSON="$REMOTE_DEVICE_LATENCY_JSON" \
SUMMARY_JSON="$SUMMARY_JSON" \
SAMPLES="$SAMPLES" \
REMOTE_HOST="$REMOTE_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_SSH_PORT="$REMOTE_SSH_PORT" \
python3 <<'PY'
import json
import math
import os
import posixpath
import queue
import re
import shlex
import socket
import statistics
import subprocess
import sys
import threading
import time
import uuid
import base64
from datetime import datetime, timezone
from pathlib import Path

spacese2e = os.environ["SPACES_E2E"]
local_db_path = os.environ["LOCAL_DB_PATH"]
local_runtime_dir = os.environ["LOCAL_RUNTIME_DIR"]
remote_result_path = Path(os.environ["REMOTE_DEVICE_RESULT_JSON"])
remote_device_latency_path = Path(os.environ["REMOTE_DEVICE_LATENCY_JSON"])
summary_json = Path(os.environ["SUMMARY_JSON"])
sample_count = int(os.environ["SAMPLES"])
remote_host = os.environ["REMOTE_HOST"]
remote_user = os.environ.get("REMOTE_USER", "").strip()
remote_ssh_port = os.environ.get("REMOTE_SSH_PORT", "").strip()
work_root = summary_json.parent
base_env = os.environ.copy()
base_env["SPACES_DB_PATH"] = local_db_path
base_env["SPACES_RUNTIME_DIR"] = local_runtime_dir
SCROLLBACK_LINE_COUNT = 6000
SCROLL_TOP_MARKER = "__SPACES_SCROLL_TOP_MARKER__"
SCROLL_BOTTOM_MARKER = "__SPACES_SCROLL_BOTTOM_MARKER__"
SCROLL_READY_MARKER = "__SPACES_SCROLL_READY_MARKER__"
SCROLL_BOUNDARY_DELTA = 900
SCROLL_BOUNDARY_MAX_ATTEMPTS = 8
SCROLL_BOUNDARY_STAGNANT_LIMIT = 2


def now_ns() -> int:
    return time.monotonic_ns()


def ms_between(start_ns: int, end_ns: int) -> float:
    return round((end_ns - start_ns) / 1_000_000, 3)


def epoch_ms() -> float:
    return time.time() * 1000


def parse_iso_epoch_ms(value: str | None) -> float | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000
    except ValueError:
        return None


def percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[max(math.ceil(len(ordered) * pct) - 1, 0)], 3)


def summarize(values: list[float]) -> dict:
    return {
        "count": len(values),
        "p50_ms": round(statistics.median(values), 3) if values else None,
        "p95_ms": percentile(values, 0.95),
        "max_ms": round(max(values), 3) if values else None,
    }


def run(command: list[str], *, env: dict | None = None, timeout: float = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, env=env or base_env, text=True, capture_output=True, check=True, timeout=timeout)


def request_json(command: list[str], *, env: dict | None = None, timeout: float = 30) -> dict:
    completed = run(command, env=env, timeout=timeout)
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"invalid JSON from {' '.join(command)}\nstdout={completed.stdout}\nstderr={completed.stderr}") from error


def iso_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def ssh_destination() -> str:
    return f"{remote_user}@{remote_host}" if remote_user else remote_host


def ssh_arguments() -> list[str]:
    args = ["ssh", "-tt", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes"]
    if remote_ssh_port:
        args += ["-p", remote_ssh_port]
    args.append(ssh_destination())
    return args


def ssh_noninteractive_arguments() -> list[str]:
    args = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes"]
    if remote_ssh_port:
        args += ["-p", remote_ssh_port]
    args.append(ssh_destination())
    return args


def ssh_command(remote_directory: str, remote_command: str) -> str:
    command = f"cd {shlex.quote(remote_directory)} && {remote_command}"
    return " ".join(shlex.quote(part) for part in ssh_arguments() + [command])


def remote_shell(command: str, timeout: float = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run(ssh_noninteractive_arguments() + [command], text=True, capture_output=True, check=True, timeout=timeout)


def mobile_request(remote: dict, payload: dict, timeout: float = 30) -> dict:
    return request_json(
        [
            spacese2e,
            "mobile-request",
            "--host",
            remote["remoteDaemonHost"],
            "--port",
            str(remote["remoteDaemonPort"]),
            f"--certificate-fingerprint={remote['certificateFingerprint']}",
            "--request-json",
            json.dumps(payload, separators=(",", ":")),
        ],
        env=os.environ.copy(),
        timeout=timeout,
    )


def remote_client_app(remote: dict) -> dict:
    return {
        "installationID": remote["macClientInstallationID"],
        "bundleID": "dev.usespaces.spaces",
        "platform": "macos",
        "deviceName": "Remote Terminal Compare",
        "appVersion": "1.0",
    }


def device_api_payload(remote: dict, command: dict) -> dict:
    return {
        "authToken": remote["macAuthToken"],
        "clientApp": remote_client_app(remote),
        "command": command,
    }


def device_request(remote: dict, command: dict, timeout: float = 30) -> tuple[dict, float]:
    started = now_ns()
    response = mobile_request(remote, device_api_payload(remote, command), timeout=timeout)
    return response, ms_between(started, now_ns())


def overview(remote: dict) -> dict:
    response = mobile_request(remote, device_api_payload(remote, {"overview": {}}))
    if not response.get("ok"):
        raise RuntimeError(response)
    return response["result"]["overview"]


def workspace_dir(remote: dict) -> str:
    target = remote.get("workspaceID")
    for workspace in overview(remote).get("workspaces") or []:
        if workspace.get("id") == target and workspace.get("dir"):
            return workspace["dir"]
    return remote["projectDir"]


class RenderTextDecoder:
    def __init__(self, label: str):
        self.label = label
        self.process = subprocess.Popen(
            [spacese2e, "render-update-text"],
            env=base_env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert self.process.stdin is not None
        assert self.process.stdout is not None

    def decode(self, line: str) -> dict:
        if self.process.poll() is not None:
            stderr = self.process.stderr.read() if self.process.stderr is not None else ""
            return {"ok": False, "error": f"render decoder exited for {self.label}: {stderr}"}
        self.process.stdin.write(line.rstrip("\n") + "\n")
        self.process.stdin.flush()
        response_line = self.process.stdout.readline()
        if not response_line:
            stderr = self.process.stderr.read() if self.process.stderr is not None else ""
            return {"ok": False, "error": f"render decoder closed for {self.label}: {stderr}"}
        try:
            return json.loads(response_line)
        except json.JSONDecodeError as error:
            return {"ok": False, "error": f"invalid render decoder JSON for {self.label}: {error}: {response_line}"}

    def close(self) -> None:
        if self.process.stdin is not None:
            try:
                self.process.stdin.close()
            except BrokenPipeError:
                pass
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()


class StreamReader:
    def __init__(self, label: str, stream, close_callback=None):
        self.label = label
        self.stream = stream
        self.close_callback = close_callback
        self.decoder = RenderTextDecoder(label)
        self.queue: queue.Queue[dict] = queue.Queue()
        self.latest: dict | None = None
        self.records: list[dict] = []
        self.thread = threading.Thread(target=self._read_loop, name=f"{label}-stream", daemon=True)
        self.thread.start()

    def _read_loop(self) -> None:
        try:
            for raw in self.stream:
                received_ns = now_ns()
                received_epoch_ms = epoch_ms()
                line = raw if isinstance(raw, str) else raw.decode("utf-8", errors="replace")
                try:
                    payload = json.loads(line)
                except json.JSONDecodeError:
                    self.records.append({"received_ns": received_ns, "decode_failed": True, "bytes": len(line.encode())})
                    continue
                render_text = self.decoder.decode(line)
                emitted_epoch_ms = parse_iso_epoch_ms(payload.get("emittedAt"))
                emitted_to_receive_wall_ms = None
                if emitted_epoch_ms is not None:
                    emitted_to_receive_wall_ms = round(received_epoch_ms - emitted_epoch_ms, 3)
                payload["_received_ns"] = received_ns
                payload["_received_epoch_ms"] = round(received_epoch_ms, 3)
                payload["_emitted_to_receive_wall_ms"] = emitted_to_receive_wall_ms
                payload["_decoded_text"] = render_text.get("text")
                payload["_decoded_text_ok"] = bool(render_text.get("ok"))
                payload["_decoded_text_error"] = render_text.get("error")
                record = {
                    "received_ns": received_ns,
                    "received_epoch_ms": round(received_epoch_ms, 3),
                    "decode_failed": False,
                    "bytes": len(line.encode()),
                    "has_render_update": bool(payload.get("renderUpdate")),
                    "render_update_bytes": len(payload.get("renderUpdate") or ""),
                    "reason": payload.get("reason"),
                    "output_byte_count": payload.get("outputByteCount"),
                    "screen_state_revision": payload.get("screenStateRevision"),
                    "emitted_to_receive_wall_ms": emitted_to_receive_wall_ms,
                    "decoded_text_ok": bool(render_text.get("ok")),
                    "decoded_text_error": render_text.get("error"),
                }
                self.records.append(record)
                self.latest = payload
                self.queue.put(payload)
        finally:
            self.decoder.close()
            if self.close_callback:
                self.close_callback()

    def wait_initial(self, timeout: float = 15) -> dict:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.latest is not None:
                return self.latest
            try:
                payload = self.queue.get(timeout=0.1)
                self.latest = payload
                return payload
            except queue.Empty:
                continue
        raise TimeoutError(f"timed out waiting for initial stream payload: {self.label}")

    def drain(self) -> None:
        while True:
            try:
                self.latest = self.queue.get_nowait()
            except queue.Empty:
                return

    def wait_idle(self, idle_ms: int = 250, timeout: float = 5) -> None:
        deadline = time.monotonic() + timeout
        idle_deadline = time.monotonic() + (idle_ms / 1000)
        while time.monotonic() < deadline:
            wait_time = max(min(idle_deadline - time.monotonic(), 0.1), 0.01)
            try:
                self.latest = self.queue.get(timeout=wait_time)
                idle_deadline = time.monotonic() + (idle_ms / 1000)
            except queue.Empty:
                if time.monotonic() >= idle_deadline:
                    return
        raise TimeoutError(f"timed out waiting for stream idle: {self.label}")

    def wait_progress(
        self,
        output_count: int,
        screen_revision: int,
        timeout: float = 10,
        accept_render_update: bool = False,
        expected_text: str | None = None,
        expected_reason: str | None = None,
        not_before_ns: int | None = None,
    ) -> tuple[dict, int]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                payload = self.queue.get(timeout=0.1)
            except queue.Empty:
                payload = self.latest
                if payload is None:
                    continue
            received_ns = int(payload.get("_received_ns") or now_ns())
            if not_before_ns is not None and received_ns < not_before_ns:
                continue
            next_output = int(payload.get("outputByteCount") or 0)
            next_revision = int(payload.get("screenStateRevision") or 0)
            has_progress = next_output > output_count or next_revision > screen_revision or (accept_render_update and payload.get("renderUpdate"))
            if not has_progress:
                continue
            if expected_reason is not None and payload.get("reason") != expected_reason:
                continue
            if expected_text is not None:
                decoded_text = payload.get("_decoded_text") or ""
                if expected_text not in decoded_text:
                    continue
                self.latest = payload
                return payload, received_ns
            self.latest = payload
            return payload, received_ns
        raise TimeoutError(
            f"timed out waiting for stream progress {self.label}; output={output_count} revision={screen_revision} latest={self.latest}"
        )


def terminal_client(client_id: str, label: str) -> dict:
    return {
        "id": client_id,
        "kind": "remoteViewer",
        "identity": {"label": label, "deviceName": label, "networkAddress": "127.0.0.1"},
        "connectedAt": iso_now(),
        "disconnectedAt": None,
    }


def local_control(socket_path: str, payload: dict, timeout: float = 10) -> tuple[dict, float, dict]:
    started = now_ns()
    connect_started = now_ns()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(timeout)
        client.connect(socket_path)
        connect_finished = now_ns()
        send_started = connect_finished
        client.sendall(json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\n")
        client.shutdown(socket.SHUT_WR)
        send_finished = now_ns()
        recv_started = send_finished
        data = b""
        while b"\n" not in data:
            chunk = client.recv(65536)
            if not chunk:
                break
            data += chunk
        recv_finished = now_ns()
    line = data.split(b"\n", 1)[0]
    decode_started = now_ns()
    response = json.loads(line.decode("utf-8"))
    finished = now_ns()
    profile = {
        "control_transport": "unix-socket",
        "local_connect_ms": ms_between(connect_started, connect_finished),
        "local_send_ms": ms_between(send_started, send_finished),
        "local_recv_ms": ms_between(recv_started, recv_finished),
        "local_decode_ms": ms_between(decode_started, finished),
        "local_response_bytes": len(line),
    }
    return response, ms_between(started, finished), profile


def unix_stream(socket_path: str):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.connect(socket_path)
    return client.makefile("r", encoding="utf-8", newline="\n"), client.close


class TargetSession:
    def __init__(self, target: str, surface: str, session_id: str, client_id: str, send_control, stream_reader: StreamReader, cleanup):
        self.target = target
        self.surface = surface
        self.session_id = session_id
        self.client_id = client_id
        self.send_control = send_control
        self.stream_reader = stream_reader
        self.cleanup = cleanup

    def attach(self) -> None:
        response, _, _ = self.send_control(
            {
                "command": "attach",
                "client": terminal_client(self.client_id, f"Latency Compare {self.surface} {self.target}"),
                "attachmentMode": "owner",
            }
        )
        if not response.get("ok", True):
            raise RuntimeError(response)
        self.stream_reader.wait_initial()

    def terminate(self) -> None:
        self.cleanup()


class LocalFactory:
    def __init__(self, remote_directory: str):
        self.remote_directory = remote_directory
        self.sessions: list[str] = []

    def start(self, title: str, remote_command: str, surface: str) -> TargetSession:
        local_cwd = work_root / "local-cwd"
        local_cwd.mkdir(parents=True, exist_ok=True)
        command = ssh_command(self.remote_directory, remote_command)
        completed = request_json(
            [spacese2e, "start-terminal-session", "--title", title, "--cwd", str(local_cwd), "--command", command],
            env=base_env,
            timeout=30,
        )
        session_id = (completed.get("id") or completed.get("sessionID") or "").upper()
        if not session_id:
            match = re.findall(r"[0-9A-Fa-f-]{36}", json.dumps(completed))
            if not match:
                raise RuntimeError(f"could not parse local session id: {completed}")
            session_id = match[-1].upper()
        self.sessions.append(session_id)
        paths = request_json([spacese2e, "profile-socket-paths", "--session-id", session_id], env=base_env)
        stream_file, stream_close = unix_stream(paths["sessionSubscriptionSocketPath"])
        reader = StreamReader(f"{surface}:local-workspace-ssh:{session_id}", stream_file, stream_close)
        client_id = f"compare-local-{uuid.uuid4()}"

        def send_control(payload: dict) -> tuple[dict, float, dict]:
            payload = dict(payload)
            payload.setdefault("clientID", client_id)
            return local_control(paths["sessionControlSocketPath"], payload)

        def cleanup() -> None:
            try:
                run([spacese2e, "terminate-terminal-session", session_id], env=base_env, timeout=30)
            except subprocess.TimeoutExpired:
                pass

        session = TargetSession("local-workspace-ssh", surface, session_id, client_id, send_control, reader, cleanup)
        session.attach()
        return session


class RemoteFactory:
    def __init__(self, remote: dict, remote_directory: str):
        self.remote = remote
        self.remote_directory = remote_directory

    def start(self, title: str, remote_command: str, surface: str) -> TargetSession:
        response, _ = device_request(self.remote, {"openWorkspaceTerminal": {"workspaceID": self.remote["workspaceID"]}}, timeout=60)
        if not response.get("ok"):
            raise RuntimeError(response)
        session_id = (((response.get("result") or {}).get("mutation") or {}).get("sessionID") or "").upper()
        if not session_id:
            raise RuntimeError(f"openWorkspaceTerminal did not return sessionID: {response}")
        client_id = f"compare-remote-{uuid.uuid4()}"
        stream_request = json.dumps(
            device_api_payload(self.remote, {"subscribe": {"sessionID": session_id, "clientID": client_id}}), separators=(",", ":")
        )
        stream_process = subprocess.Popen(
            [
                spacese2e,
                "mobile-request",
                "--host",
                self.remote["remoteDaemonHost"],
                "--port",
                str(self.remote["remoteDaemonPort"]),
                f"--certificate-fingerprint={self.remote['certificateFingerprint']}",
                "--request-json",
                stream_request,
                "--stream",
            ],
            env=os.environ.copy(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        assert stream_process.stdout is not None
        reader = StreamReader(f"{surface}:remote-workspace:{session_id}", stream_process.stdout)
        request_process = subprocess.Popen(
            [
                spacese2e,
                "mobile-request",
                "--host",
                self.remote["remoteDaemonHost"],
                "--port",
                str(self.remote["remoteDaemonPort"]),
                f"--certificate-fingerprint={self.remote['certificateFingerprint']}",
                "--request-lines",
            ],
            env=os.environ.copy(),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert request_process.stdin is not None
        assert request_process.stdout is not None
        request_lock = threading.Lock()

        def send_control(payload: dict) -> tuple[dict, float, dict]:
            payload = dict(payload)
            action = payload.pop("command")
            payload.setdefault("clientID", client_id)
            payload.setdefault("appendNewline", False)
            payload["action"] = action
            payload["sessionID"] = session_id
            request_json_line = json.dumps(
                device_api_payload(self.remote, {"terminalControl": payload}), separators=(",", ":")
            )
            started = now_ns()
            with request_lock:
                write_started = now_ns()
                request_process.stdin.write(request_json_line + "\n")
                request_process.stdin.flush()
                write_finished = now_ns()
                response_wait_started = write_finished
                response_line = request_process.stdout.readline()
                response_wait_finished = now_ns()
            if not response_line:
                exit_code = request_process.poll()
                stderr = request_process.stderr.read() if exit_code is not None and request_process.stderr is not None else ""
                raise RuntimeError(f"Device API request session closed exit={exit_code} stderr={stderr}")
            decode_started = now_ns()
            response = json.loads(response_line)
            finished = now_ns()
            profile = {
                "control_transport": "device-api-request-session",
                "request_session_stdin_write_ms": ms_between(write_started, write_finished),
                "request_session_response_wait_ms": ms_between(response_wait_started, response_wait_finished),
                "request_session_json_decode_ms": ms_between(decode_started, finished),
                "device_api_request_bytes": len(request_json_line.encode()),
                "device_api_response_bytes": len(response_line.encode()),
            }
            return response, ms_between(started, finished), profile

        def cleanup() -> None:
            if request_process.stdin is not None:
                try:
                    request_process.stdin.close()
                except BrokenPipeError:
                    pass
            try:
                request_process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                request_process.terminate()
            try:
                device_request(
                    self.remote,
                    {"stopWorkspaceTerminal": {"workspaceID": self.remote["workspaceID"], "sessionID": session_id}},
                    timeout=15,
                )
            finally:
                stream_process.terminate()
                try:
                    stream_process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    stream_process.kill()

        session = TargetSession("remote-workspace", surface, session_id, client_id, send_control, reader, cleanup)
        session.attach()
        trimmed_command = remote_command.strip()
        if trimmed_command:
            output_before, revision_before = base_counts(session)
            response, _, _ = session.send_control({"command": "send", "text": trimmed_command, "appendNewline": True})
            if not response.get("ok", True):
                raise RuntimeError(response)
            session.stream_reader.wait_progress(output_before, revision_before, timeout=20)
        return session

    def close(self) -> None:
        pass


def base_counts(session: TargetSession) -> tuple[int, int]:
    payload = session.stream_reader.latest or session.stream_reader.wait_initial()
    return int(payload.get("outputByteCount") or 0), int(payload.get("screenStateRevision") or 0)


def run_probe(
    session: TargetSession, payload: dict, timeout: float = 10, expected_text: str | None = None, expected_reason: str | None = None
) -> dict:
    session.stream_reader.drain()
    output_before, revision_before = base_counts(session)
    begin_ns = now_ns()
    response, control_ms, control_profile = session.send_control(payload)
    rpc_end_ns = now_ns()
    if not response.get("ok", True):
        raise RuntimeError(response)
    visible_payload, visible_ns = session.stream_reader.wait_progress(
        output_before,
        revision_before,
        timeout=timeout,
        accept_render_update=payload.get("command") == "scroll",
        expected_text=expected_text,
        expected_reason=expected_reason,
        not_before_ns=begin_ns,
    )
    output_after = int(visible_payload.get("outputByteCount") or 0)
    revision_after = int(visible_payload.get("screenStateRevision") or 0)
    measurement = {
        "control_request_ms": round(control_ms, 3),
        "rpc_end_to_stream_progress_ms": ms_between(rpc_end_ns, visible_ns),
        "event_to_stream_progress_ms": ms_between(begin_ns, visible_ns),
        "output_byte_delta": output_after - output_before,
        "screen_revision_delta": revision_after - revision_before,
        "visible_reason": visible_payload.get("reason"),
        "visible_has_render_update": bool(visible_payload.get("renderUpdate")),
        "visible_render_update_bytes": len(visible_payload.get("renderUpdate") or ""),
        "visible_decoded_text_ok": bool(visible_payload.get("_decoded_text_ok")),
        "visible_decoded_text_error": visible_payload.get("_decoded_text_error"),
        "expected_text_verified": None if expected_text is None else expected_text in (visible_payload.get("_decoded_text") or ""),
    }
    emitted_to_receive = visible_payload.get("_emitted_to_receive_wall_ms")
    if emitted_to_receive is not None:
        measurement["visible_emitted_to_receive_wall_ms"] = round(float(emitted_to_receive), 3)
    if session.target == "remote-workspace" and remote_rtt_ms is not None:
        measurement["control_minus_rtt_ms"] = round(control_ms - remote_rtt_ms, 3)
        measurement["rpc_end_to_stream_minus_half_rtt_ms"] = round(
            measurement["rpc_end_to_stream_progress_ms"] - (remote_rtt_ms / 2), 3)
    if measurement["rpc_end_to_stream_progress_ms"] < 0:
        measurement["stream_progress_before_control_response_ms"] = round(-measurement["rpc_end_to_stream_progress_ms"], 3)
    measurement.update(control_profile)
    return measurement


def wait_for_visible_text(session: TargetSession, expected_text: str, timeout: float = 20) -> None:
    latest = session.stream_reader.latest or session.stream_reader.wait_initial()
    if expected_text in (latest.get("_decoded_text") or ""):
        return
    output_before, revision_before = base_counts(session)
    session.stream_reader.wait_progress(
        output_before, revision_before, timeout=timeout, accept_render_update=True, expected_text=expected_text)


def visible_text(session: TargetSession) -> str:
    latest = session.stream_reader.latest or session.stream_reader.wait_initial()
    return latest.get("_decoded_text") or ""


def visible_excerpt(text: str) -> dict:
    lines = [line for line in text.splitlines() if line.strip()]
    return {
        "line_count": len(lines),
        "first_lines": lines[:5],
        "last_lines": lines[-5:],
    }


def render_metrics(session: TargetSession) -> dict:
    records = session.stream_reader.records
    emitted_to_receive_values = [
        float(item["emitted_to_receive_wall_ms"])
        for item in records
        if item.get("emitted_to_receive_wall_ms") is not None and math.isfinite(float(item["emitted_to_receive_wall_ms"]))
    ]
    return {
        "stream_event_count": len(records),
        "decode_failures": sum(1 for item in records if item.get("decode_failed")),
        "render_decode_failures": sum(1 for item in records if not item.get("decode_failed") and not item.get("decoded_text_ok")),
        "render_update_count": sum(1 for item in records if item.get("has_render_update")),
        "stream_json_bytes": sum(int(item.get("bytes") or 0) for item in records),
        "render_update_base64_bytes": sum(int(item.get("render_update_bytes") or 0) for item in records),
        "emitted_to_receive_wall": summarize(emitted_to_receive_values),
    }


def measurement_values(measurements: list[dict], key: str) -> list[float]:
    values = []
    for item in measurements:
        value = item.get(key)
        if value is None:
            continue
        try:
            number = float(value)
        except (TypeError, ValueError):
            continue
        if math.isfinite(number):
            values.append(number)
    return values


def summarize_phases(measurements: list[dict]) -> dict:
    phase_keys = {
        "control_request": "control_request_ms",
        "rpc_end_to_stream_progress": "rpc_end_to_stream_progress_ms",
        "stream_progress_before_control_response": "stream_progress_before_control_response_ms",
        "visible_emitted_to_receive_wall": "visible_emitted_to_receive_wall_ms",
        "control_minus_rtt": "control_minus_rtt_ms",
        "rpc_end_to_stream_minus_half_rtt": "rpc_end_to_stream_minus_half_rtt_ms",
        "request_session_stdin_write": "request_session_stdin_write_ms",
        "request_session_response_wait": "request_session_response_wait_ms",
        "request_session_json_decode": "request_session_json_decode_ms",
        "local_connect": "local_connect_ms",
        "local_send": "local_send_ms",
        "local_recv": "local_recv_ms",
        "local_decode": "local_decode_ms",
    }
    phase_summaries = {}
    for name, key in phase_keys.items():
        values = measurement_values(measurements, key)
        if values:
            phase_summaries[name] = summarize(values)
    return phase_summaries


def summarize_measurements(measurements: list[dict]) -> dict:
    steady_state_measurements = [item for item in measurements if int(item.get("sample_index") or 0) > 1]
    return {
        "summary_metric": "event_to_stream_progress_ms",
        "summary": summarize(measurement_values(measurements, "event_to_stream_progress_ms")),
        "steady_state_summary": summarize(measurement_values(steady_state_measurements, "event_to_stream_progress_ms")),
        "expected_text_verified_count": sum(1 for item in measurements if item.get("expected_text_verified") is True),
        "phase_summaries": summarize_phases(measurements),
        "steady_state_phase_summaries": summarize_phases(steady_state_measurements),
        "first_measurement": measurements[0] if measurements else None,
        "measurements": measurements,
    }


def input_ack_command() -> str:
    script = (
        "import sys\n"
        "sys.stdout.write('ACK_READY\\r\\n')\n"
        "sys.stdout.flush()\n"
        "while True:\n"
        "    data = sys.stdin.buffer.read(1)\n"
        "    if not data:\n"
        "        break\n"
        "    sys.stdout.write(f'ACK:{data[0]:02x}\\r\\n')\n"
        "    sys.stdout.flush()\n"
    )
    return "stty raw -echo; python3 -u -c " + shlex.quote(script)


def decoded_print_command(token: str) -> str:
    encoded_token = base64.b64encode(token.encode("utf-8")).decode("ascii")
    return "python3 -c " + shlex.quote(f"import base64; print(base64.b64decode('{encoded_token}').decode())")


def measure_input(factory, target: str, surface: str) -> dict:
    session = factory.start(f"{surface}-{target}-input-{uuid.uuid4().hex[:6]}", input_ack_command(), surface)
    try:
        wait_for_visible_text(session, "ACK_READY", timeout=20)
        measurements = []
        alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
        for index in range(sample_count):
            input_char = alphabet[index % len(alphabet)]
            expected_text = f"ACK:{input_char.encode('utf-8')[0]:02x}"
            measurement = run_probe(session, {"command": "send", "text": input_char}, timeout=10, expected_text=expected_text)
            measurement["sample_index"] = index + 1
            measurements.append(measurement)
            time.sleep(0.05)
        result = summarize_measurements(measurements)
        result["render_metrics"] = render_metrics(session)
        result["session_id"] = session.session_id
        return result
    finally:
        session.terminate()


def measure_command(factory, target: str, surface: str) -> dict:
    session = factory.start(f"{surface}-{target}-command-{uuid.uuid4().hex[:6]}", "exec /bin/bash --noprofile --norc -i", surface)
    try:
        measurements = []
        ready_token = f"__spaces_command_ready_{surface}_{target}_{uuid.uuid4().hex[:6]}__"
        run_probe(
            session,
            {"command": "send", "text": decoded_print_command(ready_token), "appendNewline": True},
            timeout=20,
            expected_text=ready_token,
        )
        for index in range(sample_count):
            token = f"__spaces_compare_{surface}_{target}_{index + 1:03d}_{uuid.uuid4().hex[:6]}__"
            command = decoded_print_command(token)
            measurement = run_probe(session, {"command": "send", "text": command, "appendNewline": True}, timeout=10, expected_text=token)
            measurement["sample_index"] = index + 1
            measurements.append(measurement)
            time.sleep(0.05)
        result = summarize_measurements(measurements)
        result["render_metrics"] = render_metrics(session)
        result["session_id"] = session.session_id
        return result
    finally:
        session.terminate()


def scroll_command() -> str:
    script = (
        "import sys,time\n"
        f"lines=['{SCROLL_TOP_MARKER}']\n"
        f"lines += [f'SCROLLLINE {{i:05d}}' for i in range({SCROLLBACK_LINE_COUNT})]\n"
        f"lines += ['{SCROLL_BOTTOM_MARKER}', '{SCROLL_READY_MARKER}']\n"
        "sys.stdout.write('\\n'.join(lines) + '\\n')\n"
        "sys.stdout.flush()\n"
        "time.sleep(120)\n"
    )
    encoded_script = base64.b64encode(script.encode("utf-8")).decode("ascii")
    return "python3 -c " + shlex.quote(f"import base64; exec(base64.b64decode('{encoded_script}'))")


def run_scroll_attempt(session: TargetSession, direction: int, timeout: float = 10) -> tuple[dict, str]:
    session.stream_reader.drain()
    before_text = visible_text(session)
    output_before, revision_before = base_counts(session)
    begin_ns = now_ns()
    response, control_ms, control_profile = session.send_control({"command": "scroll", "scrollVertical": direction})
    rpc_end_ns = now_ns()
    if not response.get("ok", True):
        raise RuntimeError(response)
    measurement = {
        "direction": direction,
        "control_request_ms": round(control_ms, 3),
        "progress_seen": False,
        "rendered_text_changed": False,
        "response_message": response.get("message"),
    }
    measurement.update(control_profile)
    try:
        visible_payload, visible_ns = session.stream_reader.wait_progress(
            output_before,
            revision_before,
            timeout=timeout,
            accept_render_update=True,
            expected_reason="scroll",
            not_before_ns=begin_ns,
        )
        after_text = visible_payload.get("_decoded_text") or ""
        measurement.update(
            {
                "progress_seen": True,
                "rpc_end_to_stream_progress_ms": ms_between(rpc_end_ns, visible_ns),
                "event_to_stream_progress_ms": ms_between(begin_ns, visible_ns),
                "screen_revision_delta": int(visible_payload.get("screenStateRevision") or 0) - revision_before,
                "output_byte_delta": int(visible_payload.get("outputByteCount") or 0) - output_before,
                "visible_reason": visible_payload.get("reason"),
                "visible_has_render_update": bool(visible_payload.get("renderUpdate")),
                "visible_render_update_bytes": len(visible_payload.get("renderUpdate") or ""),
            }
        )
        emitted_to_receive = visible_payload.get("_emitted_to_receive_wall_ms")
        if emitted_to_receive is not None:
            measurement["visible_emitted_to_receive_wall_ms"] = round(float(emitted_to_receive), 3)
    except TimeoutError as error:
        after_text = visible_text(session)
        measurement["progress_timeout"] = str(error)
    measurement["rendered_text_changed"] = after_text != before_text
    return measurement, after_text


def scroll_until_marker(session: TargetSession, marker: str, direction: int, label: str) -> dict:
    attempts = []
    current_text = visible_text(session)
    if marker in current_text:
        return {
            "ok": True,
            "label": label,
            "marker": marker,
            "direction": direction,
            "attempt_count": 0,
            "initially_visible": True,
            "last_visible_excerpt": visible_excerpt(current_text),
            "attempts": attempts,
        }
    stagnant_attempts = 0
    for index in range(SCROLL_BOUNDARY_MAX_ATTEMPTS):
        measurement, current_text = run_scroll_attempt(session, direction)
        measurement["attempt_index"] = index + 1
        measurement["marker_visible"] = marker in current_text
        attempts.append(measurement)
        if measurement["marker_visible"]:
            return {
                "ok": True,
                "label": label,
                "marker": marker,
                "direction": direction,
                "attempt_count": index + 1,
                "initially_visible": False,
                "last_visible_excerpt": visible_excerpt(current_text),
                "attempts": attempts,
            }
        if measurement.get("progress_seen") and measurement.get("rendered_text_changed"):
            stagnant_attempts = 0
        else:
            stagnant_attempts += 1
        if stagnant_attempts >= SCROLL_BOUNDARY_STAGNANT_LIMIT:
            break
        time.sleep(0.05)
    return {
        "ok": False,
        "label": label,
        "marker": marker,
        "direction": direction,
        "attempt_count": len(attempts),
        "initially_visible": False,
        "last_visible_excerpt": visible_excerpt(current_text),
        "attempts": attempts,
    }


def verify_large_scroll_region(session: TargetSession) -> dict:
    top = scroll_until_marker(session, SCROLL_TOP_MARKER, SCROLL_BOUNDARY_DELTA, "top")
    bottom = scroll_until_marker(session, SCROLL_BOTTOM_MARKER, -SCROLL_BOUNDARY_DELTA, "bottom")
    result = {
        "line_count": SCROLLBACK_LINE_COUNT,
        "top_marker": SCROLL_TOP_MARKER,
        "bottom_marker": SCROLL_BOTTOM_MARKER,
        "ready_marker": SCROLL_READY_MARKER,
        "max_attempts_per_boundary": SCROLL_BOUNDARY_MAX_ATTEMPTS,
        "top": top,
        "bottom": bottom,
        "ok": bool(top.get("ok") and bottom.get("ok")),
    }
    if not result["ok"]:
        raise RuntimeError(
            "large scroll region traversal failed: "
            + json.dumps(
                {
                    "top_ok": top.get("ok"),
                    "bottom_ok": bottom.get("ok"),
                    "top_attempts": top.get("attempt_count"),
                    "bottom_attempts": bottom.get("attempt_count"),
                    "top_last_visible": top.get("last_visible_excerpt"),
                    "bottom_last_visible": bottom.get("last_visible_excerpt"),
                },
                sort_keys=True,
            )
        )
    return result


def measure_scroll(factory, target: str, surface: str) -> dict:
    session = factory.start(f"{surface}-{target}-scroll-{uuid.uuid4().hex[:6]}", scroll_command(), surface)
    try:
        wait_for_visible_text(session, SCROLL_READY_MARKER, timeout=30)
        session.stream_reader.wait_idle(idle_ms=250, timeout=10)
        scroll_region = verify_large_scroll_region(session)
        session.stream_reader.wait_idle(idle_ms=250, timeout=10)
        measurements = []
        for index in range(sample_count):
            direction = 900 if index % 2 == 0 else -900
            measurement = run_probe(session, {"command": "scroll", "scrollVertical": direction}, timeout=10, expected_reason="scroll")
            measurement["sample_index"] = index + 1
            measurements.append(measurement)
            time.sleep(0.05)
        result = summarize_measurements(measurements)
        result["render_metrics"] = render_metrics(session)
        result["session_id"] = session.session_id
        result["scroll_region"] = scroll_region
        return result
    finally:
        session.terminate()


def compare(remote_result: dict, local_result: dict) -> dict:
    remote_p95 = (remote_result.get("summary") or {}).get("p95_ms")
    local_p95 = (local_result.get("summary") or {}).get("p95_ms")
    if remote_p95 is None or local_p95 in (None, 0):
        return {"remote_workspace_p95_ms": remote_p95, "local_ssh_p95_ms": local_p95, "delta_ms": None, "ratio": None}
    return {
        "remote_workspace_p95_ms": remote_p95,
        "local_ssh_p95_ms": local_p95,
        "delta_ms": round(remote_p95 - local_p95, 3),
        "ratio": round(remote_p95 / local_p95, 3),
    }


def reset_remote_performance_log(path: str | None) -> None:
    if not path:
        return
    directory = posixpath.dirname(path) or "."
    remote_shell(f"mkdir -p {shlex.quote(directory)} && : > {shlex.quote(path)}")


def fetch_remote_performance_log(path: str | None) -> tuple[Path | None, list[dict]]:
    if not path:
        return None, []
    local_path = work_root / "remote-device-performance.jsonl"
    completed = remote_shell(f"cat {shlex.quote(path)} 2>/dev/null || true", timeout=30)
    local_path.write_text(completed.stdout, encoding="utf-8")
    events = []
    for line in completed.stdout.splitlines():
        if not line.strip():
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return local_path, events


def remote_session_index(scenarios_payload: dict[str, dict]) -> dict[str, str]:
    sessions = {}
    for scenario_key, scenario_payload in scenarios_payload.items():
        remote_target = ((scenario_payload.get("targets") or {}).get("remote-workspace") or {})
        session_id = remote_target.get("session_id")
        if isinstance(session_id, str) and session_id:
            sessions[session_id] = scenario_key
    return sessions


def event_group_key(event: dict) -> str:
    attributes = event.get("attributes") or {}
    parts = [str(event.get("source") or "unknown"), str(event.get("name") or "unknown")]
    for key in ("action", "reason", "command", "frame_kind"):
        value = attributes.get(key)
        if value:
            parts.append(f"{key}={value}")
    return "|".join(parts)


def event_uptime_ns(event: dict) -> int | None:
    value = event.get("emittedUptimeNanoseconds")
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return None


def event_matches(event: dict, *, source: str, name: str, attributes: dict[str, str] | None = None) -> bool:
    if event.get("source") != source or event.get("name") != name:
        return False
    event_attributes = event.get("attributes") or {}
    for key, value in (attributes or {}).items():
        if event_attributes.get(key) != value:
            return False
    return True


def next_event_delta_ms(events: list[dict], start_index: int, *, source: str, name: str, attributes: dict[str, str]) -> float | None:
    start_uptime = event_uptime_ns(events[start_index])
    if start_uptime is None:
        return None
    for event in events[start_index + 1:]:
        end_uptime = event_uptime_ns(event)
        if end_uptime is None:
            continue
        if event_matches(event, source=source, name=name, attributes=attributes):
            return round((end_uptime - start_uptime) / 1_000_000, 3)
    return None


def summarize_performance_event_groups(events: list[dict]) -> dict:
    grouped: dict[str, dict] = {}
    for event in events:
        key = event_group_key(event)
        bucket = grouped.setdefault(key, {"count": 0, "elapsed_values": [], "count_values": []})
        bucket["count"] += 1
        elapsed = event.get("elapsedMS")
        if isinstance(elapsed, (int, float)):
            bucket["elapsed_values"].append(float(elapsed))
        count_value = event.get("count")
        if isinstance(count_value, (int, float)):
            bucket["count_values"].append(float(count_value))

    grouped_summary = {}
    for key, bucket in grouped.items():
        grouped_summary[key] = {
            "event_count": bucket["count"],
            "elapsed_ms": summarize(bucket["elapsed_values"]),
            "count_values": summarize(bucket["count_values"]),
        }
    return grouped_summary


def summarize_performance_timelines(events: list[dict]) -> dict:
    sorted_events = sorted(
        (event for event in events if event_uptime_ns(event) is not None),
        key=lambda event: int(event.get("emittedUptimeNanoseconds")),
    )
    deltas: dict[str, list[float]] = {
        "send_handle_to_output_observed": [],
        "send_handle_to_output_frame_publish": [],
        "send_handle_to_output_stream_send": [],
        "scroll_dispatch_to_stream_send": [],
    }

    for index, event in enumerate(sorted_events):
        if event_matches(event, source="linux-host", name="terminal_control_host_handle", attributes={"action": "send"}):
            for metric, source, name, attributes in (
                ("send_handle_to_output_observed", "linux-host", "terminal_output_observed", {}),
                (
                    "send_handle_to_output_frame_publish",
                    "linux-host",
                    "render_frame_payload_publish",
                    {"reason": "output", "frame_kind": "delta"},
                ),
                (
                    "send_handle_to_output_stream_send",
                    "device-api",
                    "stream_network_send_end",
                    {"reason": "output", "frame_kind": "delta"},
                ),
            ):
                delta = next_event_delta_ms(sorted_events, index, source=source, name=name, attributes=attributes)
                if delta is not None:
                    deltas[metric].append(delta)
        elif event_matches(event, source="device-api", name="terminal_control_dispatch_begin", attributes={"action": "scroll"}):
            delta = next_event_delta_ms(
                sorted_events,
                index,
                source="device-api",
                name="stream_network_send_end",
                attributes={"reason": "scroll", "frame_kind": "delta"},
            )
            if delta is not None:
                deltas["scroll_dispatch_to_stream_send"].append(delta)

    return {key: summarize(values) for key, values in deltas.items() if values}


def summarize_performance_events(events: list[dict], scenarios_payload: dict[str, dict], artifact_path: Path | None) -> dict:
    sessions = remote_session_index(scenarios_payload)
    filtered = [event for event in events if event.get("sessionID") in sessions]
    by_scenario: dict[str, list[dict]] = {}
    for event in filtered:
        by_scenario.setdefault(sessions[str(event.get("sessionID"))], []).append(event)
    by_scenario_events = {
        key: summarize_performance_event_groups(value)
        for key, value in sorted(by_scenario.items())
    }
    by_scenario_timelines = {
        key: summarize_performance_timelines(value)
        for key, value in sorted(by_scenario.items())
    }
    return {
        "artifact_path": str(artifact_path) if artifact_path else None,
        "remote_session_count": len(sessions),
        "event_count": len(filtered),
        "raw_event_count": len(events),
        "by_event": summarize_performance_event_groups(filtered),
        "by_scenario_event": by_scenario_events,
        "by_scenario_event_count": {key: len(value) for key, value in sorted(by_scenario.items())},
        "by_scenario_timeline": by_scenario_timelines,
    }


remote = json.loads(remote_result_path.read_text())
remote_device_latency = json.loads(remote_device_latency_path.read_text()) if remote_device_latency_path.exists() else None
remote_performance_log_path = remote.get("remotePerformanceLogPath")
reset_remote_performance_log(remote_performance_log_path)
remote_directory = workspace_dir(remote)
remote_rtt_ms = None
try:
    ping = subprocess.run(["ping", "-c", "5", "-q", remote["remoteDaemonHost"]], text=True, capture_output=True, timeout=10)
    match = re.search(r"(?:round-trip|rtt) min/avg/max/(?:stddev|mdev) = [^/]+/([^/]+)/", ping.stdout)
    if match:
        remote_rtt_ms = float(match.group(1))
except Exception:
    pass

local_factory = LocalFactory(remote_directory)
remote_factory = RemoteFactory(remote, remote_directory)
targets = {
    "remote-workspace": remote_factory,
    "local-workspace-ssh": local_factory,
}
scenario_functions = {
    "input-echo": measure_input,
    "command-output": measure_command,
    "scrollback": measure_scroll,
}
surfaces = ["mac", "ios"]
scenarios: dict[str, dict] = {}
failures: list[str] = []

try:
    for surface in surfaces:
        for scenario_name, function in scenario_functions.items():
            scenario_key = f"{surface}-{scenario_name}"
            scenario_payload = {"targets": {}}
            for target_name, factory in targets.items():
                started = now_ns()
                try:
                    result = function(factory, target_name, surface)
                    result["duration_ms"] = ms_between(started, now_ns())
                    result["target"] = target_name
                    result["surface"] = surface
                    result["transport"] = (
                        "device-api-request-session+subscribe" if target_name == "remote-workspace" else "unix-socket-local-ssh"
                    )
                    scenario_payload["targets"][target_name] = result
                except Exception as error:
                    failures.append(f"{scenario_key}:{target_name}: {error}")
                    scenario_payload["targets"][target_name] = {"error": str(error), "target": target_name, "surface": surface}
            remote_result = scenario_payload["targets"].get("remote-workspace") or {}
            local_result = scenario_payload["targets"].get("local-workspace-ssh") or {}
            scenario_payload["comparison"] = compare(remote_result, local_result)
            scenarios[scenario_key] = scenario_payload
finally:
    remote_factory.close()

remote_performance_artifact, remote_performance_events = fetch_remote_performance_log(remote_performance_log_path)
remote_performance_summary = summarize_performance_events(remote_performance_events, scenarios, remote_performance_artifact)

payload = {
    "schema_version": "remote-terminal-latency-compare/v2",
    "samples": sample_count,
    "surfaces": surfaces,
    "targets": list(targets.keys()),
    "remote_context": {
        "daemon_host": remote["remoteDaemonHost"],
        "daemon_port": int(remote["remoteDaemonPort"]),
        "ssh_destination": ssh_destination(),
        "ssh_port": int(remote_ssh_port) if remote_ssh_port else None,
        "remote_rtt_ms": remote_rtt_ms,
        "workspace_dir": remote_directory,
    },
    "current_device_api_state_polling_baseline": remote_device_latency,
    "remote_performance": remote_performance_summary,
    "scenarios": scenarios,
    "failures": failures,
}
summary_json.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"remote terminal latency comparison summary: {summary_json}")
print(
    f"remote performance events: {remote_performance_summary.get('event_count')} "
    f"(raw={remote_performance_summary.get('raw_event_count')}) artifact={remote_performance_summary.get('artifact_path')}"
)
for scenario_key, scenario_payload in scenarios.items():
    comparison = scenario_payload.get("comparison") or {}
    remote_target = ((scenario_payload.get("targets") or {}).get("remote-workspace") or {})
    local_target = ((scenario_payload.get("targets") or {}).get("local-workspace-ssh") or {})
    remote_phases = remote_target.get("phase_summaries") or {}
    local_phases = local_target.get("phase_summaries") or {}
    remote_steady = (remote_target.get("steady_state_summary") or {}).get("p95_ms")
    local_steady = (local_target.get("steady_state_summary") or {}).get("p95_ms")
    print(
        f"{scenario_key}: remote_p95={comparison.get('remote_workspace_p95_ms')}ms "
        f"local_ssh_p95={comparison.get('local_ssh_p95_ms')}ms "
        f"delta={comparison.get('delta_ms')}ms ratio={comparison.get('ratio')} "
        f"steady_remote_p95={remote_steady}ms steady_local_p95={local_steady}ms"
    )
    print(
        f"{scenario_key} phases: remote_control_p95={(remote_phases.get('control_request') or {}).get('p95_ms')}ms "
        f"remote_after_response_p95={(remote_phases.get('rpc_end_to_stream_progress') or {}).get('p95_ms')}ms "
        f"local_control_p95={(local_phases.get('control_request') or {}).get('p95_ms')}ms "
        f"local_after_response_p95={(local_phases.get('rpc_end_to_stream_progress') or {}).get('p95_ms')}ms"
    )
if failures:
    raise SystemExit("comparison failures: " + "; ".join(failures))
PY
