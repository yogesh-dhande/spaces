#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

DEMO_SCRIPT="$ROOT_DIR/apps/macos/Tests/run_mobile_terminal_demo.sh"
SPACES_CLI_BIN="${SPACES_CLI:-$ROOT_DIR/apps/macos/.build/debug/spaces}"
SPACES_E2E_BIN="${SPACES_E2E:-$ROOT_DIR/apps/macos/.build/debug/spacese2e}"
REQUESTED_KEEP_ROOT="${SPACES_MOBILE_DEMO_KEEP_ROOT:-0}"
DEFAULT_UI_TEST_CONFIG="/tmp/spaces-mobile-ui-test-config.json"
DEMO_PORT="${SPACES_MOBILE_DEMO_PORT:-}"

DEMO_STDOUT_LOG="$(mktemp "${TMPDIR:-/tmp}/spaces-mobile-roundtrip-standalone.XXXXXX")"
DEMO_PID=""
APP_PID=""
BRIDGE_PID=""
DEMO_ROOT=""
SESSION_ID=""
SECONDARY_SESSION_ID=""
BRIDGE_HOST=""
BRIDGE_PORT=""
IPAD_UDID=""
UI_TEST_CONFIG=""
ACTIVE_UI_TEST_CONFIG=""
UI_TEST_LOG=""

cleanup() {
  local exit_code=$?
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$BRIDGE_PID" ]] && kill -0 "$BRIDGE_PID" >/dev/null 2>&1; then
    kill "$BRIDGE_PID" >/dev/null 2>&1 || true
    wait "$BRIDGE_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$DEMO_PID" ]] && kill -0 "$DEMO_PID" >/dev/null 2>&1; then
    kill "$DEMO_PID" >/dev/null 2>&1 || true
    wait "$DEMO_PID" >/dev/null 2>&1 || true
  elif [[ -n "$DEMO_PID" ]]; then
    wait "$DEMO_PID" >/dev/null 2>&1 || true
  fi

  if [[ -n "$DEMO_ROOT" && -d "$DEMO_ROOT" ]]; then
    if [[ "$REQUESTED_KEEP_ROOT" == "1" || $exit_code -ne 0 ]]; then
      printf 'Preserved demo root: %s\n' "$DEMO_ROOT" >&2
    else
      rm -rf "$DEMO_ROOT" || true
    fi
  fi

  rm -f "$DEMO_STDOUT_LOG"
  if [[ -n "$ACTIVE_UI_TEST_CONFIG" ]]; then
    rm -f "$ACTIVE_UI_TEST_CONFIG"
  fi
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  if [[ -f "$DEMO_STDOUT_LOG" ]]; then
    printf '\nDemo output tail:\n' >&2
    tail -n 80 "$DEMO_STDOUT_LOG" >&2 || true
  fi
  if [[ -n "$UI_TEST_LOG" && -f "$UI_TEST_LOG" ]]; then
    printf '\nUI test output tail:\n' >&2
    tail -n 120 "$UI_TEST_LOG" >&2 || true
  fi
  if [[ -n "$DEMO_ROOT" ]]; then
    if [[ -f "$DEMO_ROOT/app.log" ]]; then
      printf '\nMac app log tail:\n' >&2
      tail -n 120 "$DEMO_ROOT/app.log" >&2 || true
    fi
    if [[ -f "$DEMO_ROOT/bridge.log" ]]; then
      printf '\nBridge log tail:\n' >&2
      tail -n 120 "$DEMO_ROOT/bridge.log" >&2 || true
    fi
  fi
  exit 1
}

resolve_demo_port() {
  if [[ -n "$DEMO_PORT" ]]; then
    return
  fi

  DEMO_PORT="$(
    python3 <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
  )"
}

wait_for_demo_metadata() {
  local metadata
  while true; do
    if metadata="$(python3 - "$DEMO_STDOUT_LOG" <<'PY'
import json
import pathlib
import shlex
import sys

log_path = pathlib.Path(sys.argv[1])
decoder = json.JSONDecoder()

text = log_path.read_text(errors="replace") if log_path.exists() else ""
index = 0
while True:
    start = text.find("{", index)
    if start < 0:
        raise SystemExit(1)
    try:
        payload, _ = decoder.raw_decode(text[start:])
    except json.JSONDecodeError:
        index = start + 1
        continue
    if isinstance(payload, dict) and payload.get("root") and payload.get("sessionID"):
        fields = {
            "DEMO_ROOT": payload["root"],
            "APP_PID": str(payload["appPID"]),
            "BRIDGE_PID": str(payload["bridgePID"]),
            "SESSION_ID": payload["sessionID"],
            "SECONDARY_SESSION_ID": payload.get("secondarySessionID") or "",
            "BRIDGE_HOST": payload["bridgeHost"],
            "BRIDGE_PORT": str(payload["bridgePort"]),
            "IPAD_UDID": payload["ipadSimulatorUDID"],
        }
        for key, value in fields.items():
            print(f"{key}={shlex.quote(value)}")
        raise SystemExit(0)
    index = start + 1
PY
    )"; then
      break
    fi
    if [[ -n "$DEMO_PID" ]] && ! kill -0 "$DEMO_PID" >/dev/null 2>&1; then
      fail "Standalone demo exited before printing metadata."
    fi
    sleep 0.25
  done
  eval "$metadata"
  UI_TEST_CONFIG="$DEMO_ROOT/roundtrip-standalone-ui-test-config.json"
  ACTIVE_UI_TEST_CONFIG="$DEFAULT_UI_TEST_CONFIG"
  UI_TEST_LOG="$DEMO_ROOT/roundtrip-standalone-ui-test.log"
}

start_demo() {
  resolve_demo_port
  printf 'Launching standalone mobile demo...\n'
  SPACES_MOBILE_DEMO_KEEP_ROOT=1 SPACES_MOBILE_DEMO_PORT="$DEMO_PORT" "$DEMO_SCRIPT" >"$DEMO_STDOUT_LOG" 2>&1 &
  DEMO_PID=$!
  wait_for_demo_metadata
  [[ -n "$SECONDARY_SESSION_ID" ]] || fail "Standalone demo did not provision a secondary terminal session."
  printf 'Demo root: %s\n' "$DEMO_ROOT"
  printf 'Primary session: %s\n' "$SESSION_ID"
  printf 'Secondary session: %s\n' "$SECONDARY_SESSION_ID"
  printf 'Bridge port: %s\n' "$DEMO_PORT"
}

write_ui_test_config() {
  python3 - "$DEMO_ROOT" "$SESSION_ID" "$BRIDGE_HOST" "$BRIDGE_PORT" "$IPAD_UDID" "$UI_TEST_CONFIG" "$ACTIVE_UI_TEST_CONFIG" <<'PY'
import json
import sys
from pathlib import Path

demo_root = Path(sys.argv[1])
session_id = sys.argv[2]
bridge_host = sys.argv[3]
bridge_port = int(sys.argv[4])
ipad_udid = sys.argv[5]
config_paths = [Path(sys.argv[6]), Path(sys.argv[7])]

pairing = json.loads((demo_root / "pairing.json").read_text())
ipad_pairing = pairing["ipad"]

payload = {
    "sessionID": session_id,
    "host": bridge_host,
    "port": bridge_port,
    "authToken": ipad_pairing["authToken"],
    "transportKey": ipad_pairing["transportKey"],
    "installationID": ipad_pairing["installationID"],
    "renderDumpPath": str(demo_root / "roundtrip-standalone-ipad-render.json"),
    "eventLogPath": str(demo_root / "roundtrip-standalone-ipad-events.jsonl"),
    "immediateScreenshotPath": str(demo_root / "roundtrip-standalone-ipad-post-takeover-immediate.png"),
    "shortDelayScreenshotPath": str(demo_root / "roundtrip-standalone-ipad-post-takeover-plus-2s.png"),
    "longDelayScreenshotPath": str(demo_root / "roundtrip-standalone-ipad-post-takeover-plus-6s.png"),
    "proceedTakeOverPath": str(demo_root / "roundtrip-standalone-ipad-proceed-takeover"),
    "firstCommandRequestPath": str(demo_root / "roundtrip-standalone-ipad-first-command-request"),
    "firstCommandFocusedPath": str(demo_root / "roundtrip-standalone-ipad-first-command-focused"),
    "firstCommandCompletedPath": str(demo_root / "roundtrip-standalone-ipad-first-command-completed"),
    "firstCommandObservedPath": str(demo_root / "roundtrip-standalone-ipad-first-command-observed"),
    "secondCommandRequestPath": str(demo_root / "roundtrip-standalone-ipad-second-command-request"),
    "secondCommandFocusedPath": str(demo_root / "roundtrip-standalone-ipad-second-command-focused"),
    "secondCommandCompletedPath": str(demo_root / "roundtrip-standalone-ipad-second-command-completed"),
    "secondCommandObservedPath": str(demo_root / "roundtrip-standalone-ipad-second-command-observed"),
    "proceedFinishPath": str(demo_root / "roundtrip-standalone-ipad-proceed-finish"),
    "firstCommandText": "echo __roundtrip_ipad_one__",
    "secondCommandText": "echo __roundtrip_ipad_two__",
    "manualRetakeoverAttempts": 2,
    "manualRetakeoverObservedPrefix": str(demo_root / "roundtrip-standalone-ipad-manual-retakeover-observed"),
    "postFirstCommandScreenshotPath": str(demo_root / "roundtrip-standalone-ipad-post-first-command.png"),
    "postSecondCommandScreenshotPath": str(demo_root / "roundtrip-standalone-ipad-post-second-command.png"),
    "finalMacRetakeoverRequestPath": str(demo_root / "roundtrip-standalone-ipad-final-mac-retakeover-request"),
    "finalMacRetakeoverObservedPath": str(demo_root / "roundtrip-standalone-ipad-final-mac-retakeover-observed"),
    "postFinalMacRetakeoverScreenshotPath": str(demo_root / "roundtrip-standalone-ipad-post-final-mac-retakeover.png"),
    "finalScreenshotPath": str(demo_root / "roundtrip-standalone-ipad-final.png"),
    "attachToExistingApp": True,
    "bundleID": "com.yogeshdhande.spacesmobile",
    "ipadUDID": ipad_udid,
}

encoded = json.dumps(payload, indent=2, sort_keys=True)
for config_path in config_paths:
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(encoded)
PY
}

run_roundtrip() {
  python3 - "$ROOT_DIR" "$DEMO_ROOT" "$SESSION_ID" "$BRIDGE_HOST" "$BRIDGE_PORT" "$IPAD_UDID" "$SPACES_CLI_BIN" "$SPACES_E2E_BIN" "$UI_TEST_CONFIG" "$UI_TEST_LOG" <<'PY'
import json
import os
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

repo_root = Path(sys.argv[1])
demo_root = Path(sys.argv[2])
session_id = sys.argv[3]
bridge_host = sys.argv[4]
bridge_port = int(sys.argv[5])
ipad_udid = sys.argv[6]
spaces_cli = Path(sys.argv[7])
spacese2e = Path(sys.argv[8])
ui_test_config = Path(sys.argv[9])
ui_test_log = Path(sys.argv[10])
runtime_root = demo_root / "runtime"
attachments_path = runtime_root / "terminal" / "sessions" / session_id / "attachments.json"
output_log_path = runtime_root / "terminal" / "sessions" / session_id / "output.log"

config = json.loads(ui_test_config.read_text())
render_dump_path = Path(config["renderDumpPath"])
event_log_path = Path(config["eventLogPath"])
command_request_path = Path(f"{event_log_path}.command-request.json")
proceed_takeover_path = Path(config["proceedTakeOverPath"])
first_command_request = Path(config["firstCommandRequestPath"])
first_command_focused = Path(config["firstCommandFocusedPath"])
first_command_completed = Path(config["firstCommandCompletedPath"])
first_command_observed = Path(config["firstCommandObservedPath"])
second_command_request = Path(config["secondCommandRequestPath"])
second_command_focused = Path(config["secondCommandFocusedPath"])
second_command_completed = Path(config["secondCommandCompletedPath"])
second_command_observed = Path(config["secondCommandObservedPath"])
proceed_finish_path = Path(config["proceedFinishPath"])
manual_retakeover_prefix = Path(config["manualRetakeoverObservedPrefix"])
final_mac_retakeover_request = Path(config["finalMacRetakeoverRequestPath"])
final_mac_retakeover_observed = Path(config["finalMacRetakeoverObservedPath"])

env = os.environ | {
    "HOME": str(demo_root / "home"),
    "SPACES_DB_PATH": str(demo_root / "spaces.db"),
    "SPACES_RUNTIME_DIR": str(runtime_root),
}

mac_prepare_commands = [
    "printf '__roundtrip_mac_before_takeover_one__\\n'",
    "printf '__roundtrip_mac_before_takeover_two__\\n'",
]
ios_first_command = config["firstCommandText"]
ios_first_output = "__roundtrip_ipad_one__"
ios_second_command = config["secondCommandText"]
ios_second_output = "__roundtrip_ipad_two__"
bare_command_lines = (
    "s",
    ios_first_command,
    ios_second_command,
)

def check_ui_test_alive(process: subprocess.Popen[str]) -> None:
    return_code = process.poll()
    if return_code is None:
        return
    log_tail = ui_test_log.read_text(errors="replace")[-12000:] if ui_test_log.exists() else "<missing>"
    raise RuntimeError(f"Standalone round-trip UI test exited early with status {return_code}.\n{log_tail}")

def wait_for_file(path: Path, timeout: float, process: subprocess.Popen[str]) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        check_ui_test_alive(process)
        if path.exists():
            return
        time.sleep(0.2)
    raise RuntimeError(f"Timed out waiting for file at {path}")

def write_marker(path: Path, value: str = "done\n") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value)

def socket_path(root: Path, session_id: str) -> Path:
    hash_value = 5381
    for byte in f"{root}|{session_id}".encode("utf-8"):
        hash_value = ((hash_value << 5) + hash_value + byte) & 0xFFFFFFFFFFFFFFFF
    return Path("/tmp/spaces-terminal-sockets") / f"{hash_value:016x}.sock"

def current_owner_client_id(excluded_client_ids: set[str] | None = None) -> str:
    excluded_client_ids = excluded_client_ids or set()
    payload = json.loads(attachments_path.read_text())
    for attachment in payload:
        if attachment.get("mode") == "owner" and attachment.get("detachedAt") is None:
            client_id = attachment.get("clientID")
            if client_id and client_id not in excluded_client_ids:
                return client_id
    raise RuntimeError(f"No active owner attachment was found.\n{json.dumps(payload, indent=2)}")

def wait_for_active_owner(excluded_client_ids: set[str] | None = None, timeout: float = 20) -> str:
    deadline = time.time() + timeout
    last_snapshot = ""
    while time.time() < deadline:
        if attachments_path.exists():
            payload = json.loads(attachments_path.read_text())
            last_snapshot = json.dumps(payload, indent=2, sort_keys=True)
            for attachment in payload:
                if attachment.get("mode") == "owner" and attachment.get("detachedAt") is None:
                    client_id = attachment.get("clientID")
                    if client_id and client_id not in (excluded_client_ids or set()):
                        return client_id
        time.sleep(0.1)
    raise RuntimeError(f"Timed out waiting for active owner.\n{last_snapshot}")

def send_unix_control_request(request: dict) -> dict:
    path = socket_path(demo_root, session_id)
    deadline = time.time() + 10
    while True:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(5)
        try:
            client.connect(str(path))
            client.sendall(json.dumps(request).encode("utf-8"))
            client.shutdown(socket.SHUT_WR)
            response = bytearray()
            while True:
                chunk = client.recv(4096)
                if not chunk:
                    break
                response.extend(chunk)
            return json.loads(response.decode("utf-8"))
        except (ConnectionRefusedError, FileNotFoundError):
            if time.time() >= deadline:
                raise
            time.sleep(0.2)
        finally:
            client.close()

def send_owner_command(command_text: str) -> None:
    owner_client_id = current_owner_client_id()
    for request in (
        {"command": "send", "text": command_text, "clientID": owner_client_id},
        {"command": "key", "key": "enter", "clientID": owner_client_id},
    ):
        response = send_unix_control_request(request)
        if not response.get("ok"):
            raise RuntimeError(f"Owner control request failed: {response}")

def wait_for_render_dump(predicate, timeout: float, process: subprocess.Popen[str]) -> dict:
    deadline = time.time() + timeout
    last_payload = None
    while time.time() < deadline:
        check_ui_test_alive(process)
        if render_dump_path.exists():
            try:
                payload = json.loads(render_dump_path.read_text())
            except json.JSONDecodeError:
                time.sleep(0.1)
                continue
            last_payload = payload
            if predicate(payload):
                return payload
        time.sleep(0.2)
    if last_payload is not None and predicate(last_payload):
        return last_payload
    raise RuntimeError(
        f"Timed out waiting for render dump at {render_dump_path}.\n"
        f"Last payload: {json.dumps(last_payload or {}, indent=2)}"
    )

def wait_for_terminal_window_dump(output_path: Path, predicate, timeout: float, any_mode: bool) -> dict:
    deadline = time.time() + timeout
    last_payload = None
    while time.time() < deadline:
        if output_path.exists():
            output_path.unlink()
        command = [str(spacese2e), "dump-terminal-session-window-state", "--session-id", session_id, "--output-path", str(output_path)]
        if any_mode:
            command.append("--any-mode")
        subprocess.run(command, capture_output=True, text=True, env=env, check=True)
        file_deadline = time.time() + 1.0
        while time.time() < file_deadline:
            if output_path.exists():
                try:
                    payload = json.loads(output_path.read_text())
                except json.JSONDecodeError:
                    time.sleep(0.05)
                    continue
                last_payload = payload
                if predicate(payload):
                    return payload
                break
            time.sleep(0.05)
        time.sleep(0.2)
    raise RuntimeError(
        f"Timed out waiting for terminal window dump at {output_path}.\n"
        f"Last payload: {json.dumps(last_payload or {}, indent=2)}"
    )

def contains_command_output(text: str, command_text: str, output_text: str) -> bool:
    return f"% {command_text}" in text and f"\n{output_text}\n" in text

def assert_render_output_sane(label: str, text: str) -> None:
    if "command not found: s" in text:
        raise RuntimeError(f"{label} render contains split input failure:\n{text}")
    if re.search(r"(?m)^%$", text):
        raise RuntimeError(f"{label} render contains stray percent line:\n{text}")
    for line in text.splitlines():
        if line.count("%") > 1:
            raise RuntimeError(f"{label} render contains duplicated prompt on one line:\n{text}")
        if line.strip() in bare_command_lines:
            raise RuntimeError(f"{label} render contains a bare replay command line:\n{text}")
    if text.count("Last login:") > 1:
        raise RuntimeError(f"{label} render contains repeated login banner:\n{text}")
    if "\x1b" in text or "^[" in text:
        raise RuntimeError(f"{label} render contains raw escape remnants:\n{text}")

def write_command_request(command_text: str, send_enter: bool = True) -> None:
    payload = {
        "id": f"{int(time.time() * 1000)}-{os.getpid()}",
        "text": command_text,
        "sendEnter": send_enter,
    }
    command_request_path.parent.mkdir(parents=True, exist_ok=True)
    command_request_path.write_text(json.dumps(payload, sort_keys=True))

def wait_for_output_log_text(text: str, timeout: float, process: subprocess.Popen[str]) -> None:
    deadline = time.time() + timeout
    last_output = ""
    while time.time() < deadline:
        check_ui_test_alive(process)
        if output_log_path.exists():
            last_output = output_log_path.read_text(errors="replace")
            if text in last_output:
                return
        time.sleep(0.2)
    raise RuntimeError(f"Timed out waiting for {text!r} in {output_log_path}.\nLast output tail:\n{last_output[-4000:]}")

def assert_status_shell_hides_live_content(label: str, payload: dict) -> None:
    if payload.get("showsTerminalSurface") is not False:
        raise RuntimeError(f"{label} unexpectedly mounted a live terminal surface:\n{json.dumps(payload, indent=2)}")
    visible_text = payload.get("visibleText") or payload.get("renderedOutput") or ""
    if "Current owner:" not in visible_text:
        raise RuntimeError(f"{label} did not show the takeover status shell:\n{json.dumps(payload, indent=2)}")
    if "__roundtrip_" in visible_text:
        raise RuntimeError(f"{label} exposed live terminal content:\n{json.dumps(payload, indent=2)}")

def request_mac_retakeover(expected_previous_owner: str) -> str:
    show_result = subprocess.run(
        [str(spaces_cli), "terminal", "show", session_id],
        capture_output=True,
        text=True,
        env=env,
        check=True,
    )
    if "Requested owner terminal window" not in show_result.stdout:
        raise RuntimeError(f"Mac retakeover did not report success:\n{show_result.stdout}\n{show_result.stderr}")
    reclaimed_owner = wait_for_active_owner(excluded_client_ids={expected_previous_owner}, timeout=20)
    if reclaimed_owner == expected_previous_owner:
        raise RuntimeError("Mac retakeover did not transfer ownership away from iPad.")
    return reclaimed_owner

ui_test_command = [
    "xcodebuild",
    "-project",
    "apps/ios/SpacesMobile.xcodeproj",
    "-scheme",
    "SpacesMobile",
    "-destination",
    f"platform=iOS Simulator,id={ipad_udid}",
    "-derivedDataPath",
    str(demo_root / "RoundTripAttachUITestDerivedData"),
    "-only-testing:SpacesMobileUITests/SpacesMobileUITests/testTerminalTakeOverRoundTripWithCommands",
    "test",
]

mac_owner_dump_path = demo_root / "roundtrip-standalone-mac-owner-dump.json"
mac_status_dump_path = demo_root / "roundtrip-standalone-mac-status-dump.json"

with ui_test_log.open("w") as ui_test_output:
    ui_test_process = subprocess.Popen(
        ui_test_command,
        cwd=repo_root,
        stdout=ui_test_output,
        stderr=subprocess.STDOUT,
        text=True,
        env=os.environ | {"SPACES_MOBILE_UI_TEST_CONFIG_PATH": str(ui_test_config)},
    )

    try:
        for command_text in mac_prepare_commands:
            send_owner_command(command_text)
            time.sleep(0.5)

        mac_owner_payload = wait_for_terminal_window_dump(
            mac_owner_dump_path,
            lambda payload: (
                payload.get("found") is True
                and payload.get("showsTerminalSurface") is True
                and "__roundtrip_mac_before_takeover_one__" in (payload.get("renderedOutput") or "")
                and "__roundtrip_mac_before_takeover_two__" in (payload.get("renderedOutput") or "")
            ),
            timeout=45,
            any_mode=False,
        )
        expected_render_text = mac_owner_payload.get("renderedOutput") or ""
        if not expected_render_text:
            raise RuntimeError(f"Unable to derive canonical Mac owner render text:\n{json.dumps(mac_owner_payload, indent=2)}")
        assert_render_output_sane("Mac owner before takeover", expected_render_text)

        write_marker(proceed_takeover_path, "go\n")

        ipad_owner_payload = wait_for_render_dump(
            lambda payload: (
                payload.get("sessionID") == session_id
                and payload.get("isOwner") is True
                and payload.get("isBusy") is False
                and payload.get("isSynchronizingOwnership") is False
                and payload.get("isInputSurfaceReady") is True
                and (payload.get("renderedText") or payload.get("snapshotText") or "").strip()
            ),
            timeout=40,
            process=ui_test_process,
        )
        if ipad_owner_payload.get("errorMessage"):
            raise RuntimeError(f"iPad reported an error after first takeover:\n{json.dumps(ipad_owner_payload, indent=2)}")
        ipad_owner_text = ipad_owner_payload.get("snapshotText") or ipad_owner_payload.get("renderedText") or ""
        if "__roundtrip_mac_before_takeover_one__" not in ipad_owner_text or "__roundtrip_mac_before_takeover_two__" not in ipad_owner_text:
            raise RuntimeError(
                "iPad owner render did not include the Mac pre-takeover transcript markers:\n"
                f"{json.dumps(ipad_owner_payload, indent=2)}"
            )

        write_marker(first_command_request, "go\n")
        wait_for_file(first_command_focused, timeout=30, process=ui_test_process)
        write_command_request(ios_first_command)
        wait_for_output_log_text(ios_first_output, timeout=20, process=ui_test_process)
        write_marker(first_command_completed)
        wait_for_file(first_command_observed, timeout=20, process=ui_test_process)

        write_marker(second_command_request, "go\n")
        wait_for_file(second_command_focused, timeout=30, process=ui_test_process)
        write_command_request(ios_second_command)
        wait_for_output_log_text(ios_second_output, timeout=20, process=ui_test_process)
        write_marker(second_command_completed)
        wait_for_file(second_command_observed, timeout=20, process=ui_test_process)

        ipad_owner_client_id = wait_for_active_owner(timeout=10)
        request_mac_retakeover(ipad_owner_client_id)
        ipad_after_mac_retakeover = wait_for_render_dump(
            lambda payload: (
                payload.get("sessionID") == session_id
                and payload.get("isOwner") is False
                and payload.get("showsTerminalSurface") is False
                and (payload.get("renderedText") or "") == ""
                and "Current owner:" in (payload.get("visibleText") or "")
            ),
            timeout=20,
            process=ui_test_process,
        )
        if ipad_after_mac_retakeover.get("errorMessage"):
            raise RuntimeError(f"iPad reported an error after Mac retakeover:\n{json.dumps(ipad_after_mac_retakeover, indent=2)}")

        mac_owner_after_retakeover = wait_for_terminal_window_dump(
            mac_owner_dump_path,
            lambda payload: (
                payload.get("found") is True
                and payload.get("showsTerminalSurface") is True
                and contains_command_output(payload.get("renderedOutput") or "", ios_first_command, ios_first_output)
                and contains_command_output(payload.get("renderedOutput") or "", ios_second_command, ios_second_output)
            ),
            timeout=20,
            any_mode=False,
        )
        assert_render_output_sane("Mac after first retakeover", mac_owner_after_retakeover.get("renderedOutput") or "")
        write_marker(proceed_finish_path)

        for attempt_index in range(2):
            takeover_number = attempt_index + 2
            wait_for_file(Path(f"{manual_retakeover_prefix}-{attempt_index + 1}"), timeout=30, process=ui_test_process)
            ipad_after_manual_takeover = wait_for_render_dump(
                lambda payload: (
                    payload.get("sessionID") == session_id
                    and payload.get("isOwner") is True
                    and payload.get("isBusy") is False
                    and payload.get("isSynchronizingOwnership") is False
                    and payload.get("isInputSurfaceReady") is True
                    and (payload.get("renderedText") or payload.get("snapshotText") or "").strip()
                ),
                timeout=20,
                process=ui_test_process,
            )
            if ipad_after_manual_takeover.get("errorMessage"):
                raise RuntimeError(
                    f"iPad reported an error after takeover {takeover_number}:\n{json.dumps(ipad_after_manual_takeover, indent=2)}"
                )

            mac_status_payload = wait_for_terminal_window_dump(
                mac_status_dump_path,
                lambda payload: payload.get("found") is True and payload.get("showsTerminalSurface") is False,
                timeout=20,
                any_mode=True,
            )
            assert_status_shell_hides_live_content(f"Mac status after iPad takeover {takeover_number}", mac_status_payload)

            if attempt_index >= 1:
                continue

            current_ipad_owner = wait_for_active_owner(timeout=10)
            request_mac_retakeover(current_ipad_owner)
            ipad_after_mac_retakeover = wait_for_render_dump(
                lambda payload: (
                    payload.get("sessionID") == session_id
                    and payload.get("isOwner") is False
                    and payload.get("showsTerminalSurface") is False
                    and (payload.get("renderedText") or "") == ""
                    and "Current owner:" in (payload.get("visibleText") or "")
                ),
                timeout=20,
                process=ui_test_process,
            )
            if ipad_after_mac_retakeover.get("errorMessage"):
                raise RuntimeError(
                    f"iPad reported an error after Mac retakeover {takeover_number}:\n{json.dumps(ipad_after_mac_retakeover, indent=2)}"
                )
            mac_owner_after_retakeover = wait_for_terminal_window_dump(
                mac_owner_dump_path,
                lambda payload: (
                    payload.get("found") is True
                    and payload.get("showsTerminalSurface") is True
                    and contains_command_output(payload.get("renderedOutput") or "", ios_first_command, ios_first_output)
                    and contains_command_output(payload.get("renderedOutput") or "", ios_second_command, ios_second_output)
                ),
                timeout=20,
                any_mode=False,
            )
            assert_render_output_sane(
                f"Mac after retakeover {takeover_number}",
                mac_owner_after_retakeover.get("renderedOutput") or "",
            )

        final_ipad_owner = wait_for_active_owner(timeout=10)
        request_mac_retakeover(final_ipad_owner)
        ipad_after_final_mac_retakeover = wait_for_render_dump(
            lambda payload: (
                payload.get("sessionID") == session_id
                and payload.get("isOwner") is False
                and payload.get("showsTerminalSurface") is False
                and (payload.get("renderedText") or "") == ""
                and "Current owner:" in (payload.get("visibleText") or "")
            ),
            timeout=20,
            process=ui_test_process,
        )
        if ipad_after_final_mac_retakeover.get("errorMessage"):
            raise RuntimeError(
                f"iPad reported an error after the final Mac retakeover:\n{json.dumps(ipad_after_final_mac_retakeover, indent=2)}"
            )
        mac_owner_after_final_retakeover = wait_for_terminal_window_dump(
            mac_owner_dump_path,
            lambda payload: (
                payload.get("found") is True
                and payload.get("showsTerminalSurface") is True
                and contains_command_output(payload.get("renderedOutput") or "", ios_first_command, ios_first_output)
                and contains_command_output(payload.get("renderedOutput") or "", ios_second_command, ios_second_output)
            ),
            timeout=20,
            any_mode=False,
        )
        assert_render_output_sane("Mac after final retakeover", mac_owner_after_final_retakeover.get("renderedOutput") or "")
        write_marker(final_mac_retakeover_request, "go\n")
        wait_for_file(final_mac_retakeover_observed, timeout=20, process=ui_test_process)

        return_code = ui_test_process.wait(timeout=120)
        if return_code != 0:
            log_tail = ui_test_log.read_text(errors="replace")[-12000:] if ui_test_log.exists() else "<missing>"
            raise RuntimeError(f"Standalone round-trip UI test failed with status {return_code}.\n{log_tail}")

        if not render_dump_path.exists():
            raise RuntimeError(f"Expected final iPad render dump at {render_dump_path}")
        if not event_log_path.exists():
            raise RuntimeError(f"Expected iPad event log at {event_log_path}")
    finally:
        if ui_test_process.poll() is None:
            ui_test_process.terminate()
            try:
                ui_test_process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                ui_test_process.kill()
                ui_test_process.wait(timeout=10)
PY
}

start_demo
write_ui_test_config
run_roundtrip
printf 'Standalone round-trip takeover test passed.\n'
