#!/usr/bin/env python3

import argparse
import base64
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Callable


def iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def acquire_terminal_harness_lock() -> Callable[[], None]:
    if os.environ.get("SPACES_TERMINAL_HARNESS_LOCK_HELD") == "1":
        return lambda: None

    lock_root = Path(
        os.environ.get(
            "SPACES_TERMINAL_HARNESS_LOCK_DIR",
            str(Path(tempfile.gettempdir()) / "spaces-terminal-harness.lock"),
        )
    )
    waited = 0
    while True:
        try:
            lock_root.mkdir()
            break
        except FileExistsError:
            owner_pid_path = lock_root / "pid"
            if owner_pid_path.exists():
                owner_pid_text = owner_pid_path.read_text(encoding="utf-8").strip()
                if owner_pid_text:
                    try:
                        os.kill(int(owner_pid_text), 0)
                    except (ValueError, ProcessLookupError):
                        shutil.rmtree(lock_root, ignore_errors=True)
                        continue
                    except PermissionError:
                        pass
            time.sleep(0.2)
            waited += 1
            if waited == 50:
                print(f"Waiting for terminal harness lock at {lock_root}", file=sys.stderr)

    (lock_root / "pid").write_text(f"{os.getpid()}\n", encoding="utf-8")

    released = False

    def release() -> None:
        nonlocal released
        if released:
            return
        shutil.rmtree(lock_root, ignore_errors=True)
        released = True

    return release


def send_tcp_control_request(host: str, port: int, request: dict) -> dict:
    client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    client.settimeout(5)
    client.connect((host, port))
    client.sendall(json.dumps(request).encode("utf-8") + b"\n")
    client.shutdown(socket.SHUT_WR)
    response = bytearray()
    while True:
        chunk = client.recv(4096)
        if not chunk:
            break
        response.extend(chunk)
    client.close()
    return json.loads(response.decode("utf-8"))


def connect_stream(host: str, port: int, request: dict) -> socket.socket:
    stream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    stream.settimeout(10)
    stream.connect((host, port))
    stream.sendall(json.dumps(request).encode("utf-8") + b"\n")
    stream.shutdown(socket.SHUT_WR)
    return stream


def wait_for_proxy_ready(process: subprocess.Popen[str], timeout: float = 10) -> tuple[str, int]:
    deadline = time.time() + timeout
    while time.time() < deadline:
        line = process.stdout.readline().strip()
        if not line:
            continue
        match = re.search(r"host=([0-9.]+)\tport=(\d+)", line)
        if match:
            return match.group(1), int(match.group(2))
    raise RuntimeError("Timed out waiting for mobile bridge to become ready.")


def wait_for_proxy_ready_in_file(log_path: Path, timeout: float = 10) -> tuple[str, int]:
    deadline = time.time() + timeout
    last_size = 0
    while time.time() < deadline:
        if log_path.exists():
            text = log_path.read_text(encoding="utf-8", errors="replace")
            if len(text) != last_size:
                last_size = len(text)
                match = re.search(r"host=([0-9.]+)\tport=(\d+)", text)
                if match:
                    return match.group(1), int(match.group(2))
        time.sleep(0.1)
    contents = log_path.read_text(encoding="utf-8", errors="replace") if log_path.exists() else ""
    raise RuntimeError(f"Timed out waiting for mobile bridge to become ready. Log contents:\n{contents}")


def assert_process_alive(process: subprocess.Popen[str], label: str, stdout_path: Path | None = None, stderr_path: Path | None = None) -> None:
    status = process.poll()
    if status is None:
        return
    details = [f"{label} exited unexpectedly with status {status}."]
    if stdout_path is not None and stdout_path.exists():
        details.append(f"{label} stdout:\n{stdout_path.read_text(encoding='utf-8', errors='replace')}")
    if stderr_path is not None and stderr_path.exists():
        details.append(f"{label} stderr:\n{stderr_path.read_text(encoding='utf-8', errors='replace')}")
    raise RuntimeError("\n\n".join(details))


def wait_for_stream_condition(stream: socket.socket, predicate, timeout: float = 10) -> dict:
    deadline = time.time() + timeout
    buffer = bytearray()
    last_payload = None
    last_skipped_line = None
    while time.time() < deadline:
        try:
            chunk = stream.recv(65536)
        except TimeoutError:
            continue
        if not chunk:
            break
        buffer.extend(chunk)
        while b"\n" in buffer:
            line, _, remainder = buffer.partition(b"\n")
            buffer[:] = remainder
            line = line.strip()
            if not line:
                continue
            decoded = line.decode("utf-8", errors="replace").strip()
            if not decoded:
                continue
            try:
                payload = json.loads(decoded)
            except json.JSONDecodeError:
                if not decoded.startswith("{"):
                    last_skipped_line = decoded
                    continue
                raise RuntimeError(
                    "Received an invalid JSON terminal-state line.\n"
                    f"LINE: {decoded}\n"
                    f"LAST PAYLOAD: {json.dumps(last_payload or {}, indent=2)}"
                )
            last_payload = payload
            if predicate(payload):
                return payload
    detail = f"Last payload: {json.dumps(last_payload or {}, indent=2)}"
    if last_skipped_line is not None:
        detail += f"\nLast skipped line: {last_skipped_line}"
    raise RuntimeError(f"Timed out waiting for streamed terminal state. {detail}")


def terminal_sessions_root(profile_root: Path, runtime_root: Path | None = None) -> Path:
    runtime_sessions_root = runtime_root / "terminal" / "sessions" if runtime_root is not None else None
    profile_sessions_root = profile_root / "terminal" / "sessions"
    if runtime_sessions_root is not None and runtime_sessions_root.exists():
        return runtime_sessions_root
    return profile_sessions_root


def wait_for_active_owner(
    profile_root: Path, session_id: str, excluded_client_ids: set[str] | None = None, timeout: float = 10, runtime_root: Path | None = None
) -> str:
    excluded_client_ids = excluded_client_ids or set()
    attachments_path = terminal_sessions_root(profile_root, runtime_root) / session_id / "attachments.json"
    deadline = time.time() + timeout
    last_snapshot = ""
    while time.time() < deadline:
        if attachments_path.exists():
            payload = json.loads(attachments_path.read_text())
            last_snapshot = json.dumps(payload, indent=2, sort_keys=True)
            for attachment in payload:
                if attachment.get("mode") == "owner" and attachment.get("detachedAt") is None:
                    client_id = attachment.get("clientID")
                    if client_id and client_id not in excluded_client_ids:
                        return client_id
        time.sleep(0.1)
    raise RuntimeError(f"Timed out waiting for active owner attachment. Last snapshot:\n{last_snapshot}")


def read_service_pid(profile_root: Path, session_id: str, runtime_root: Path | None = None) -> int | None:
    state_path = terminal_sessions_root(profile_root, runtime_root) / session_id / "state.json"
    if not state_path.exists():
        return None
    payload = json.loads(state_path.read_text())
    pid = payload.get("servicePID")
    return int(pid) if pid is not None else None


def start_spaces_app(spaces_app: Path, env: dict[str, str]) -> subprocess.Popen[str]:
    return subprocess.Popen(
        [str(spaces_app)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )


def resolve_built_binary(repo_root: Path, env_name: str, default_name: str) -> Path:
    explicit = os.environ.get(env_name)
    if explicit:
        return Path(explicit)

    direct = repo_root / "apps/macos/.build/debug" / default_name
    if direct.exists():
        return direct

    matches = sorted((repo_root / "apps/macos/.build").glob(f"**/{default_name}"))
    for match in matches:
        if match.is_file() and ".dSYM" not in str(match):
            return match

    return direct


def discover_session_ids(profile_root: Path, runtime_root: Path | None = None) -> list[str]:
    sessions_root = terminal_sessions_root(profile_root, runtime_root)
    if not sessions_root.exists():
        return []
    return sorted(path.name for path in sessions_root.iterdir() if path.is_dir())


def wait_for_new_session_id(profile_root: Path, existing_ids: set[str], timeout: float = 20, runtime_root: Path | None = None) -> str:
    deadline = time.time() + timeout
    while time.time() < deadline:
        current_ids = discover_session_ids(profile_root, runtime_root)
        new_ids = [session_id for session_id in current_ids if session_id not in existing_ids]
        if new_ids:
            return new_ids[-1]
        time.sleep(0.25)
    raise RuntimeError(
        f"Timed out waiting for a new session id. Existing ids: {sorted(existing_ids)} current ids: {discover_session_ids(profile_root, runtime_root)}"
    )


def socket_path(profile_root: Path, session_id: str, runtime_root: Path | None = None) -> Path:
    def hashed_socket(root: Path) -> Path:
        hash_value = 5381
        for byte in f"{root}|{session_id}".encode("utf-8"):
            hash_value = ((hash_value << 5) + hash_value + byte) & 0xFFFFFFFFFFFFFFFF
        return Path("/tmp/spaces-terminal-sockets") / f"{hash_value:016x}.sock"

    profile_socket = hashed_socket(profile_root)
    if profile_socket.exists():
        return profile_socket
    if runtime_root is not None:
        runtime_socket = hashed_socket(runtime_root)
        if runtime_socket.exists():
            return runtime_socket
    return profile_socket


def send_unix_control_request(control_socket: Path, request: dict) -> dict:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(5)
    client.connect(str(control_socket))
    client.sendall(json.dumps(request).encode("utf-8"))
    client.shutdown(socket.SHUT_WR)
    response = bytearray()
    while True:
        chunk = client.recv(4096)
        if not chunk:
            break
        response.extend(chunk)
    client.close()
    return json.loads(response.decode("utf-8"))


def active_owner_is(client_id: str):
    def predicate(payload: dict) -> bool:
        snapshot = payload.get("attachmentSnapshot") or {}
        attachments = snapshot.get("attachments") or []
        return any(
            attachment.get("mode") == "owner"
            and attachment.get("detachedAt") is None
            and attachment.get("clientID") == client_id
            for attachment in attachments
        )

    return predicate


def plain_text(payload: dict) -> str:
    if payload.get("transcriptTail"):
        return payload["transcriptTail"]
    if payload.get("snapshotText"):
        return payload["snapshotText"]

    snapshot = payload.get("snapshot") or {}
    columns = int(snapshot.get("columns") or 0)
    rows = int(snapshot.get("rows") or 0)
    cells = snapshot.get("cells") or []
    if columns <= 0 or rows <= 0 or len(cells) < columns * rows:
        return ""

    lines: list[str] = []
    for row in range(rows):
        start = row * columns
        row_cells = cells[start : start + columns]
        characters = []
        for cell in row_cells:
            codepoint = int(cell.get("codepoint") or 0)
            characters.append(chr(codepoint) if codepoint > 0 else " ")
        lines.append("".join(characters).rstrip())
    return "\n".join(lines)


def state_plain_text(state: dict) -> str:
    snapshot = state.get("snapshot") or {}
    if snapshot:
        return plain_text({"snapshot": snapshot})
    if state.get("snapshotText"):
        return state["snapshotText"]
    if state.get("transcriptTail"):
        return state["transcriptTail"]
    output_data = state.get("outputData")
    if output_data:
        try:
            return base64.b64decode(output_data).decode("utf-8", errors="replace")
        except Exception:
            return ""
    return ""


def snapshot_contains(needle: str):
    return lambda payload: needle in state_plain_text(payload)


def resolve_ios_app_path() -> Path:
    explicit = os.environ.get("SPACES_IOS_APP") or os.environ.get("SPACES_MOBILE_DEMO_APP_PATH")
    if explicit:
        path = Path(explicit)
        if path.is_dir():
            return path
        raise RuntimeError(f"SpacesMobile.app not found at {path}")

    derived_data_root = Path.home() / "Library/Developer/Xcode/DerivedData"
    candidates = sorted(
        derived_data_root.glob("SpacesMobile-*/Build/Products/Debug-iphonesimulator/SpacesMobile.app"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        raise RuntimeError("SpacesMobile.app not found in DerivedData. Build it with xcodebuild first.")
    return candidates[0]


def resolve_simulator_udid(device_name: str) -> str:
    payload = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True))
    for runtime_devices in payload.get("devices", {}).values():
        for device in runtime_devices:
            if device.get("name") == device_name and device.get("isAvailable", True):
                return str(device["udid"])
    raise RuntimeError(f"Simulator not found: {device_name}")


def boot_simulator(udid: str) -> None:
    subprocess.run(["xcrun", "simctl", "boot", udid], capture_output=True, text=True)
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True, capture_output=True, text=True)


def write_simulator_settings(
    udid: str,
    bundle_id: str,
    host: str,
    port: int,
    installation_id: str,
    auth_token: str,
    ios_app_path: Path,
) -> None:
    subprocess.run(["xcrun", "simctl", "terminate", udid, bundle_id], capture_output=True, text=True)
    subprocess.run(["xcrun", "simctl", "uninstall", udid, bundle_id], capture_output=True, text=True)
    subprocess.run(["xcrun", "simctl", "install", udid, str(ios_app_path)], check=True, capture_output=True, text=True)
    container = subprocess.check_output(["xcrun", "simctl", "get_app_container", udid, bundle_id, "data"], text=True).strip()
    prefs_path = Path(container) / "Library/Preferences" / f"{bundle_id}.plist"
    prefs_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "host": host,
        "port": port,
        "authToken": auth_token,
        "installationID": installation_id,
    }
    encoded = json.dumps(payload).encode("utf-8")
    if prefs_path.exists():
        import plistlib

        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    else:
        prefs = {}
    prefs["spaces.mobile.connection-settings"] = encoded
    import plistlib

    with prefs_path.open("wb") as handle:
        plistlib.dump(prefs, handle, fmt=plistlib.FMT_BINARY)


def launch_simulator_app(udid: str, bundle_id: str, child_environment: dict[str, str]) -> None:
    launch_env = os.environ.copy()
    for key, value in child_environment.items():
        launch_env[f"SIMCTL_CHILD_{key}"] = value
    subprocess.run(["xcrun", "simctl", "launch", udid, bundle_id], check=True, capture_output=True, text=True, env=launch_env)


def start_ios_ui_test(
    repo_root: Path,
    simulator_udid: str,
    launch_environment: dict[str, str],
    derived_data_path: Path,
    stdout_path: Path,
    stderr_path: Path,
) -> tuple[subprocess.Popen[str], list[str]]:
    command = [
        "xcodebuild",
        "-project",
        str(repo_root / "apps/ios/SpacesMobile.xcodeproj"),
        "-scheme",
        "SpacesMobile",
        "-destination",
        f"platform=iOS Simulator,id={simulator_udid}",
        "-derivedDataPath",
        str(derived_data_path),
        "-only-testing:SpacesMobileUITests/SpacesMobileUITests/testTerminalTakeOverFromList",
        "test",
    ]
    stdout_path.parent.mkdir(parents=True, exist_ok=True)
    stderr_path.parent.mkdir(parents=True, exist_ok=True)
    stdout_handle = stdout_path.open("w")
    stderr_handle = stderr_path.open("w")
    process = subprocess.Popen(command, stdout=stdout_handle, stderr=stderr_handle, text=True, env=os.environ | launch_environment)
    stdout_handle.close()
    stderr_handle.close()
    return process, command


def tail_text_file(path: Path, limit: int = 12000) -> str:
    if not path.exists():
        return ""
    content = path.read_text(errors="replace")
    if len(content) <= limit:
        return content
    return content[-limit:]


def wait_for_ios_ui_test(process: subprocess.Popen[str], command: list[str], stdout_path: Path, stderr_path: Path) -> None:
    process.wait()
    stdout = tail_text_file(stdout_path)
    stderr = tail_text_file(stderr_path)
    if process.returncode != 0:
        raise RuntimeError(
            "iOS UI test failed.\n"
            f"Command: {' '.join(command)}\n"
            f"STDOUT:\n{stdout}\n"
            f"STDERR:\n{stderr}"
        )


def wait_for_json_file(path: Path, timeout: float = 20) -> dict:
    deadline = time.time() + timeout
    last_error = ""
    while time.time() < deadline:
        if path.exists():
            try:
                return json.loads(path.read_text())
            except Exception as exc:  # noqa: BLE001
                last_error = repr(exc)
        time.sleep(0.2)
    raise RuntimeError(f"Timed out waiting for JSON file at {path}. Last error: {last_error}")


def wait_for_render_dump(path: Path, predicate, timeout: float = 30) -> dict:
    deadline = time.time() + timeout
    last_payload = None
    while time.time() < deadline:
        if path.exists():
            try:
                payload = json.loads(path.read_text())
            except Exception:
                payload = None
            if isinstance(payload, dict):
                last_payload = payload
                if predicate(payload):
                    return payload
        time.sleep(0.25)
    raise RuntimeError(f"Timed out waiting for render dump at {path}. Last payload: {json.dumps(last_payload or {}, indent=2)}")


def wait_for_file(path: Path, timeout: float = 20) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists():
            return
        time.sleep(0.2)
    raise RuntimeError(f"Timed out waiting for file at {path}")


def send_simulator_hardware_text(command_text: str) -> None:
    script = r'''
on run argv
    set typedText to item 1 of argv
    tell application "Simulator" to activate
    delay 0.2
    tell application "System Events"
        tell process "Simulator"
            set frontmost to true
            keystroke typedText
            key code 36
        end tell
    end tell
end run
'''
    subprocess.run(
        ["osascript", "-", command_text],
        input=script,
        text=True,
        capture_output=True,
        check=True,
    )


def read_json_file(path: Path) -> dict | None:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def wait_for_terminal_window_dump(
    spacese2e: Path,
    env: dict[str, str],
    session_id: str,
    output_path: Path,
    viewer: bool | None,
    predicate,
    timeout: float = 20,
) -> dict:
    deadline = time.time() + timeout
    last_payload = None
    while time.time() < deadline:
        if output_path.exists():
            output_path.unlink()
        command = [str(spacese2e), "dump-terminal-session-window-state", "--session-id", session_id, "--output-path", str(output_path)]
        if viewer is True:
            command.append("--viewer")
        elif viewer is None:
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
        time.sleep(0.25)
    raise RuntimeError(
        f"Timed out waiting for terminal window dump at {output_path}."
        f" Last payload: {json.dumps(last_payload or {}, indent=2)}"
    )


def assert_render_output_sane(label: str, text: str, bare_command_lines: tuple[str, ...] = ()) -> None:
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


def normalize_terminal_text(text: str) -> str:
    lines = [line.rstrip() for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n")]
    normalized: list[str] = []
    for line in lines:
        if line.startswith("Last login: "):
            normalized.append("Last login: <dynamic>")
        else:
            normalized.append(line)
    while normalized and normalized[-1] == "":
        normalized.pop()
    return "\n".join(normalized)


def assert_exact_terminal_text(label: str, text: str, expected: str) -> None:
    normalized_actual = normalize_terminal_text(text)
    normalized_expected = normalize_terminal_text(expected)
    if normalized_actual != normalized_expected:
        raise RuntimeError(
            f"{label} render did not match the pre-takeover owner content.\n"
            f"EXPECTED:\n{normalized_expected}\n\nACTUAL:\n{normalized_actual}"
        )


def collect_json_lines(path: Path) -> list[dict]:
    if not path.exists():
        return []
    payloads: list[dict] = []
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        payloads.append(json.loads(line))
    return payloads


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--start-app", action="store_true", help="Launch an isolated SpacesApp instance for the POC.")
    args = parser.parse_args()
    release_harness_lock = acquire_terminal_harness_lock()

    repo_root = Path(__file__).resolve().parents[3]
    spaces_cli = resolve_built_binary(repo_root, "SPACES_CLI", "spaces")
    spaces_app = resolve_built_binary(repo_root, "SPACES_APP", "SpacesApp")
    spacese2e = resolve_built_binary(repo_root, "SPACES_E2E", "spacese2e")
    temp_root = Path(tempfile.mkdtemp(prefix="spaces-mobile-poc."))
    temp_home = temp_root / "home"
    temp_home.mkdir(parents=True, exist_ok=True)
    db_path = temp_root / "spaces.db"
    runtime_dir = temp_root / "runtime"
    runtime_dir.mkdir(parents=True, exist_ok=True)
    ios_bundle_id = "com.yogeshdhande.spacesmobile"
    env = os.environ | {
        "HOME": str(temp_home),
        "SPACES_DB_PATH": str(db_path),
        "SPACES_RUNTIME_DIR": str(runtime_dir),
    }

    fixture = (
        "python3 -u -c "
        "\"import sys; print('ready', flush=True); "
        "index = 0\n"
        "for line in sys.stdin:\n"
        "    text = line.rstrip('\\\\n')\n"
        "    print(f'line{index}:{text}', flush=True)\n"
        "    index += 1\""
    )

    app_process = None
    bridge_process = None
    session_id = None
    mobile_client = None
    service_pid = None
    stream = None
    ui_test_process = None
    bridge_stdout_handle = None
    bridge_stderr_handle = None
    bridge_stdout_path = None
    bridge_stderr_path = None
    preserve_artifacts = False
    preserve_success_artifacts = os.environ.get("SPACES_MOBILE_E2E_PRESERVE_SUCCESS", "").lower() in {"1", "true", "yes", "on"}
    try:
        if args.start_app:
            app_process = start_spaces_app(spaces_app, env)
            time.sleep(2)

        result = subprocess.run(
            [
                str(spaces_cli),
                "terminal",
                "command",
                "--command",
                fixture,
                "--title",
                "mobile-poc",
            ],
            capture_output=True,
            text=True,
            env=env,
            check=True,
        )
        match = re.search(r"Started terminal session ([A-F0-9-]+)", result.stdout, re.IGNORECASE)
        if not match:
            raise RuntimeError(f"Unable to parse session id from:\n{result.stdout}")
        session_id = match.group(1)
        service_pid = read_service_pid(temp_root, session_id, runtime_dir)
        control_socket = socket_path(temp_root, session_id, runtime_dir)

        pairing_code = "246810"
        bridge_stdout_path = temp_root / "mobile-bridge.stdout.log"
        bridge_stderr_path = temp_root / "mobile-bridge.stderr.log"
        bridge_stdout_handle = bridge_stdout_path.open("w+", encoding="utf-8")
        bridge_stderr_handle = bridge_stderr_path.open("w+", encoding="utf-8")
        bridge_process = subprocess.Popen(
            [
                str(spaces_cli),
                "mobile",
                "serve",
                "--host",
                "127.0.0.1",
                "--port",
                "0",
                "--pairing-code",
                pairing_code,
            ],
            stdout=bridge_stdout_handle,
            stderr=bridge_stderr_handle,
            text=True,
            env=env | {"SPACES_MOBILE_BRIDGE_TRACE": "1"},
        )
        bridge_host, bridge_port = wait_for_proxy_ready_in_file(bridge_stdout_path)
        assert_process_alive(bridge_process, "mobile bridge", bridge_stdout_path, bridge_stderr_path)

        client_app = {
            "installationID": str(uuid.uuid4()).upper(),
            "bundleID": "com.yogeshdhande.spacesmobile",
            "platform": "ios",
            "deviceName": "iPhone Simulator",
            "appVersion": "1.0",
        }
        paired = send_tcp_control_request(
            bridge_host, bridge_port, {"command": "pair", "pairingCode": pairing_code, "clientApp": client_app}
        )
        if not paired.get("ok"):
            raise RuntimeError(f"Pairing failed: {paired}")
        auth_token = paired.get("issuedAuthToken")
        if not auth_token:
            raise RuntimeError(f"Mobile bridge did not return an auth token: {paired}")

        def send_request(request: dict) -> dict:
            return send_tcp_control_request(
                bridge_host, bridge_port, {"authToken": auth_token, "clientApp": client_app, **request}
            )

        def wait_for_session_state(session_id: str, predicate, timeout: float = 10) -> dict:
            deadline = time.time() + timeout
            last_state: dict | None = None
            while time.time() < deadline:
                payload = send_request({"command": "state", "sessionID": session_id})
                state = payload.get("sessionState") or {}
                last_state = state
                if predicate(state):
                    return state
                time.sleep(0.25)
            raise RuntimeError(f"Timed out waiting for session state. Last state:\n{json.dumps(last_state or {}, indent=2)}")

        mobile_client = {
            "id": str(uuid.uuid4()).upper(),
            "kind": "remoteViewer",
            "identity": {"label": "iphone-viewer", "deviceName": "iPhone", "networkAddress": "10.0.0.24"},
            "connectedAt": iso_now(),
            "disconnectedAt": None,
        }

        response = send_request(
            {"command": "attach", "sessionID": session_id, "client": mobile_client, "attachmentMode": "viewer"}
        )
        if not response.get("ok"):
            raise RuntimeError(f"Attach failed: {response}")

        stream = connect_stream(
            bridge_host,
            bridge_port,
            {"authToken": auth_token, "clientApp": client_app, "command": "subscribe", "sessionID": session_id, "clientID": mobile_client["id"]},
        )
        wait_for_stream_condition(stream, snapshot_contains("ready"))
        initial_owner_client_id = wait_for_active_owner(
            temp_root, session_id, excluded_client_ids={mobile_client["id"]}, runtime_root=runtime_dir
        )

        blocked = send_request(
            {"command": "send", "sessionID": session_id, "text": "blocked", "appendNewline": True, "clientID": mobile_client["id"]}
        )
        if blocked.get("ok"):
            raise RuntimeError(f"Viewer input should have been rejected: {blocked}")

        subprocess.run(
            [str(spacese2e), "close-terminal-session-window", "--session-id", session_id],
            capture_output=True,
            text=True,
            env=env,
            check=True,
        )
        time.sleep(1)

        takeover = send_request({"command": "takeover", "sessionID": session_id, "clientID": mobile_client["id"]})
        if not takeover.get("ok"):
            raise RuntimeError(f"Takeover failed: {takeover}")
        wait_for_stream_condition(stream, active_owner_is(mobile_client["id"]))

        sent = send_request({"command": "send", "sessionID": session_id, "text": "mobile-hello", "clientID": mobile_client["id"]})
        if not sent.get("ok"):
            raise RuntimeError(f"Mobile send failed: {sent}")
        key = send_request({"command": "key", "sessionID": session_id, "key": "enter", "clientID": mobile_client["id"]})
        if not key.get("ok"):
            raise RuntimeError(f"Mobile key failed: {key}")
        wait_for_session_state(session_id, lambda state: "line0:mobile-hello" in state_plain_text(state))

        show_result = subprocess.run(
            [str(spaces_cli), "terminal", "show", session_id],
            capture_output=True,
            text=True,
            env=env,
            check=True,
        )
        if "Requested owner terminal window" not in show_result.stdout:
            raise RuntimeError(f"Owner window reopen did not report success:\n{show_result.stdout}\n{show_result.stderr}")

        reopened_owner_client_id = wait_for_active_owner(
            temp_root, session_id, excluded_client_ids={mobile_client["id"], initial_owner_client_id}, runtime_root=runtime_dir
        )
        wait_for_stream_condition(stream, active_owner_is(reopened_owner_client_id))

        blocked_after_retake = send_request(
            {"command": "send", "sessionID": session_id, "text": "blocked-again", "appendNewline": True, "clientID": mobile_client["id"]}
        )
        if blocked_after_retake.get("ok"):
            raise RuntimeError(f"Mobile client should have lost ownership: {blocked_after_retake}")

        owner_sent = send_unix_control_request(
            control_socket, {"command": "send", "text": "desktop-return", "clientID": reopened_owner_client_id}
        )
        if not owner_sent.get("ok"):
            raise RuntimeError(f"Reopened owner send failed: {owner_sent}")
        owner_key = send_unix_control_request(control_socket, {"command": "key", "key": "enter", "clientID": reopened_owner_client_id})
        if not owner_key.get("ok"):
            raise RuntimeError(f"Reopened owner key failed: {owner_key}")
        wait_for_session_state(session_id, lambda state: "line1:desktop-return" in state_plain_text(state))

        if args.start_app:
            render_project = temp_root / "render-project"
            (render_project / "src").mkdir(parents=True, exist_ok=True)
            (render_project / "README.md").write_text("# Mobile Render Fixture\n")
            (render_project / "src" / "demo.py").write_text('print("hello demo")\n')
            subprocess.run(["git", "init", "-q", "-b", "main"], cwd=render_project, check=True, capture_output=True, text=True)
            subprocess.run(["git", "add", "README.md", "src/demo.py"], cwd=render_project, check=True, capture_output=True, text=True)
            subprocess.run(
                ["git", "commit", "-q", "-m", "Initial demo repo"],
                cwd=render_project,
                check=True,
                capture_output=True,
                text=True,
                env=os.environ | {
                    "GIT_AUTHOR_NAME": "Codex",
                    "GIT_AUTHOR_EMAIL": "codex@example.com",
                    "GIT_COMMITTER_NAME": "Codex",
                    "GIT_COMMITTER_EMAIL": "codex@example.com",
                },
            )

            subprocess.run(
                [
                    str(spacese2e),
                    "seed-fixture",
                    "--project-dir",
                    str(render_project),
                    "--docs-url",
                    "http://127.0.0.1:20001",
                    "--admin-url",
                    "http://127.0.0.1:20002",
                    "--workspace-title",
                    "Mobile Render",
                ],
                capture_output=True,
                text=True,
                env=env | {"SPACES_PROJECT_DIR": str(repo_root)},
                check=True,
            )
            existing_render_session_ids = set(discover_session_ids(temp_root, runtime_dir))
            subprocess.run(
                [str(spacese2e), "open-workspace-terminal", "--workspace-dir", str(render_project)],
                capture_output=True,
                text=True,
                env=env,
                check=True,
            )
            render_session_id = wait_for_new_session_id(temp_root, existing_render_session_ids, timeout=30, runtime_root=runtime_dir)

            wait_for_terminal_window_dump(
                spacese2e,
                env,
                render_session_id,
                temp_root / "mac-owner-dump.json",
                viewer=False,
                predicate=lambda payload: (
                    payload.get("found") is True
                    and payload.get("showsTerminalSurface") is True
                    and f"{render_project.name} %" in (payload.get("renderedOutput") or "")
                ),
                timeout=45,
            )
            render_owner_client_id = wait_for_active_owner(temp_root, render_session_id, timeout=10, runtime_root=runtime_dir)
            render_control_socket = socket_path(temp_root, render_session_id, runtime_dir)

            ipad_udid = resolve_simulator_udid(os.environ.get("SPACES_MOBILE_E2E_IPAD_NAME", "iPad Pro 13-inch (M5)"))
            iphone_udid = resolve_simulator_udid(os.environ.get("SPACES_MOBILE_E2E_IPHONE_NAME", "iPhone 17 Pro"))
            ios_app_path = resolve_ios_app_path()
            subprocess.run(["open", "-a", "Simulator"], capture_output=True, text=True)
            boot_simulator(ipad_udid)
            boot_simulator(iphone_udid)

            ipad_client_app = {
                "installationID": str(uuid.uuid4()).upper(),
                "bundleID": ios_bundle_id,
                "platform": "ios",
                "deviceName": "iPad Pro 13-inch (M5)",
                "appVersion": "1.0",
            }
            pair_response = send_tcp_control_request(
                bridge_host, bridge_port, {"command": "pair", "pairingCode": pairing_code, "clientApp": ipad_client_app}
            )
            if not pair_response.get("ok") or not pair_response.get("issuedAuthToken"):
                raise RuntimeError(f"Pairing failed for iPad simulator: {pair_response}")

            iphone_client_app = {
                "installationID": str(uuid.uuid4()).upper(),
                "bundleID": ios_bundle_id,
                "platform": "ios",
                "deviceName": "iPhone 17 Pro",
                "appVersion": "1.0",
            }
            iphone_pair_response = send_tcp_control_request(
                bridge_host, bridge_port, {"command": "pair", "pairingCode": pairing_code, "clientApp": iphone_client_app}
            )
            if not iphone_pair_response.get("ok") or not iphone_pair_response.get("issuedAuthToken"):
                raise RuntimeError(f"Pairing failed for iPhone simulator: {iphone_pair_response}")

            write_simulator_settings(
                ipad_udid,
                ios_bundle_id,
                bridge_host,
                bridge_port,
                ipad_client_app["installationID"],
                str(pair_response["issuedAuthToken"]),
                ios_app_path,
            )
            write_simulator_settings(
                iphone_udid,
                ios_bundle_id,
                bridge_host,
                bridge_port,
                iphone_client_app["installationID"],
                str(iphone_pair_response["issuedAuthToken"]),
                ios_app_path,
            )
            launch_simulator_app(iphone_udid, ios_bundle_id, {})

            ipad_render_dump = temp_root / "ipad-render.json"
            ipad_event_log = temp_root / "ipad-events.jsonl"
            ipad_immediate_screenshot = temp_root / "ipad-post-takeover-immediate.png"
            ipad_short_delay_screenshot = temp_root / "ipad-post-takeover-plus-2s.png"
            ipad_long_delay_screenshot = temp_root / "ipad-post-takeover-plus-6s.png"
            ipad_proceed_takeover = temp_root / "ipad-proceed-takeover"
            ipad_first_command_request = temp_root / "ipad-first-command-request"
            ipad_first_command_focused = temp_root / "ipad-first-command-focused"
            ipad_first_command_completed = temp_root / "ipad-first-command-completed"
            ipad_first_command_observed = temp_root / "ipad-first-command-observed"
            ipad_second_command_request = temp_root / "ipad-second-command-request"
            ipad_second_command_focused = temp_root / "ipad-second-command-focused"
            ipad_second_command_completed = temp_root / "ipad-second-command-completed"
            ipad_second_command_observed = temp_root / "ipad-second-command-observed"
            ipad_proceed_finish = temp_root / "ipad-proceed-finish"
            ipad_post_first_command_screenshot = temp_root / "ipad-post-ios-first-command.png"
            ipad_post_second_command_screenshot = temp_root / "ipad-post-ios-second-command.png"
            ipad_post_mac_retakeover_screenshot = temp_root / "ipad-post-mac-retakeover.png"
            mac_viewer_dump_path = temp_root / "mac-demoted-owner-dump.json"
            mac_reclaimed_owner_dump_path = temp_root / "mac-reclaimed-owner-dump.json"
            ui_test_derived_data = temp_root / "SpacesMobileUITestDerivedData"
            ui_test_stdout = temp_root / "ios-ui-test.stdout.log"
            ui_test_stderr = temp_root / "ios-ui-test.stderr.log"
            ios_first_command_text = "which tailscale"
            ios_second_command_text = "echo __spaces_second_command__"
            ui_test_config_path = Path("/tmp/spaces-mobile-ui-test-config.json")
            ui_test_config_path.write_text(
                json.dumps(
                    {
                        "sessionID": render_session_id,
                        "host": bridge_host,
                        "port": bridge_port,
                        "authToken": str(pair_response["issuedAuthToken"]),
                        "installationID": ipad_client_app["installationID"],
                        "renderDumpPath": str(ipad_render_dump),
                        "eventLogPath": str(ipad_event_log),
                        "immediateScreenshotPath": str(ipad_immediate_screenshot),
                        "shortDelayScreenshotPath": str(ipad_short_delay_screenshot),
                        "longDelayScreenshotPath": str(ipad_long_delay_screenshot),
                        "proceedTakeOverPath": str(ipad_proceed_takeover),
                        "firstCommandRequestPath": str(ipad_first_command_request),
                        "firstCommandFocusedPath": str(ipad_first_command_focused),
                        "firstCommandCompletedPath": str(ipad_first_command_completed),
                        "firstCommandObservedPath": str(ipad_first_command_observed),
                        "secondCommandRequestPath": str(ipad_second_command_request),
                        "secondCommandFocusedPath": str(ipad_second_command_focused),
                        "secondCommandCompletedPath": str(ipad_second_command_completed),
                        "secondCommandObservedPath": str(ipad_second_command_observed),
                        "proceedFinishPath": str(ipad_proceed_finish),
                        "firstCommandText": ios_first_command_text,
                        "secondCommandText": ios_second_command_text,
                        "postFirstCommandScreenshotPath": str(ipad_post_first_command_screenshot),
                        "postSecondCommandScreenshotPath": str(ipad_post_second_command_screenshot),
                        "finalScreenshotPath": str(ipad_post_mac_retakeover_screenshot),
                    },
                    indent=2,
                    sort_keys=True,
                )
            )
            ui_test_process, ui_test_command = start_ios_ui_test(
                repo_root,
                ipad_udid,
                {
                    "SPACES_MOBILE_UI_TEST_CONFIG_PATH": str(ui_test_config_path),
                },
                ui_test_derived_data,
                ui_test_stdout,
                ui_test_stderr,
            )
            initial_viewer_payload = wait_for_render_dump(
                ipad_render_dump,
                lambda payload: payload.get("sessionID") == render_session_id and payload.get("isOwner") is False,
                timeout=30,
            )

            for command_text in ("ls",):
                response = send_unix_control_request(
                    render_control_socket,
                    {"command": "send", "text": command_text, "clientID": render_owner_client_id},
                )
                if not response.get("ok"):
                    raise RuntimeError(f"Render owner send failed: {response}")
                response = send_unix_control_request(
                    render_control_socket,
                    {"command": "key", "key": "enter", "clientID": render_owner_client_id},
                )
                if not response.get("ok"):
                    raise RuntimeError(f"Render owner key failed: {response}")
                time.sleep(1.0)

            mac_owner_after_ls_payload = wait_for_terminal_window_dump(
                spacese2e,
                env,
                render_session_id,
                temp_root / "mac-owner-after-ls-dump.json",
                viewer=False,
                predicate=lambda payload: (
                    payload.get("found") is True
                    and payload.get("showsTerminalSurface") is True
                    and "README.md" in (payload.get("renderedOutput") or "")
                    and "src" in (payload.get("renderedOutput") or "")
                ),
                timeout=20,
            )
            initial_runtime_columns = initial_viewer_payload.get("runtimeColumns")
            initial_runtime_rows = initial_viewer_payload.get("runtimeRows")
            expected_render_text = mac_owner_after_ls_payload.get("renderedOutput") or ""
            if not expected_render_text:
                raise RuntimeError(
                    f"Unable to derive canonical pre-takeover render text from Mac owner dump:\n{json.dumps(mac_owner_after_ls_payload, indent=2)}"
                )

            ipad_proceed_takeover.write_text("go\n")

            wait_for_render_dump(
                ipad_render_dump,
                lambda payload: payload.get("sessionID") == render_session_id and payload.get("isOwner") is True,
                timeout=40,
            )
            assert_process_alive(bridge_process, "mobile bridge", bridge_stdout_path, bridge_stderr_path)
            time.sleep(0.5)
            ipad_payload = wait_for_render_dump(
                ipad_render_dump,
                lambda payload: (
                    payload.get("sessionID") == render_session_id
                    and payload.get("isOwner") is True
                    and payload.get("isBusy") is False
                    and payload.get("isSynchronizingOwnership") is False
                ),
                timeout=20,
            )
            mac_viewer_payload = wait_for_terminal_window_dump(
                spacese2e,
                env,
                render_session_id,
                mac_viewer_dump_path,
                viewer=None,
                predicate=lambda payload: (
                    payload.get("found") is True
                    and payload.get("showsTerminalSurface") is True
                    and normalize_terminal_text(payload.get("renderedOutput") or "") == normalize_terminal_text(expected_render_text)
                ),
                timeout=30,
            )
            wait_for_file(ipad_immediate_screenshot, timeout=10)
            wait_for_file(ipad_short_delay_screenshot, timeout=10)
            wait_for_file(ipad_long_delay_screenshot, timeout=15)

            assert_render_output_sane("iPad", ipad_payload.get("renderedText", ""), bare_command_lines=("ls",))
            assert_exact_terminal_text("iPad", ipad_payload.get("renderedText", ""), expected_render_text)
            if ipad_payload.get("errorMessage"):
                raise RuntimeError(f"iPad render reported an error after takeover:\n{json.dumps(ipad_payload, indent=2)}")
            if (
                initial_runtime_columns is not None
                and initial_runtime_rows is not None
                and (
                    ipad_payload.get("runtimeColumns") != initial_runtime_columns
                    or ipad_payload.get("runtimeRows") != initial_runtime_rows
                )
            ):
                raise RuntimeError(
                    "iPad takeover changed the live terminal geometry:\n"
                    f"expected={initial_runtime_columns}x{initial_runtime_rows}\n"
                    f"actual={ipad_payload.get('runtimeColumns')}x{ipad_payload.get('runtimeRows')}\n"
                    f"{json.dumps(ipad_payload, indent=2)}"
                )

            mac_rendered_output = mac_viewer_payload.get("renderedOutput") or ""
            assert_render_output_sane("Mac viewer", mac_rendered_output, bare_command_lines=("ls",))
            assert_exact_terminal_text("Mac viewer", mac_rendered_output, expected_render_text)
            if mac_viewer_payload.get("showsOutputFallback"):
                raise RuntimeError(f"Mac viewer unexpectedly fell back to output view:\n{json.dumps(mac_viewer_payload, indent=2)}")

            ipad_first_command_request.write_text("go\n")
            wait_for_file(ipad_first_command_focused, timeout=20)
            send_simulator_hardware_text(ios_first_command_text)
            assert_process_alive(bridge_process, "mobile bridge", bridge_stdout_path, bridge_stderr_path)
            ipad_after_command_payload = wait_for_render_dump(
                ipad_render_dump,
                lambda payload: payload.get("sessionID") == render_session_id
                and payload.get("isOwner") is True
                and f"% {ios_first_command_text}" in payload.get("renderedText", "")
                and "/usr/local/bin/tailscale" in payload.get("renderedText", ""),
                timeout=20,
            )
            ipad_first_command_completed.write_text("done\n")
            wait_for_file(ipad_post_first_command_screenshot, timeout=20)
            wait_for_file(ipad_first_command_observed, timeout=20)
            assert_process_alive(bridge_process, "mobile bridge", bridge_stdout_path, bridge_stderr_path)
            mac_viewer_after_command_payload = wait_for_terminal_window_dump(
                spacese2e,
                env,
                render_session_id,
                mac_viewer_dump_path,
                viewer=None,
                predicate=lambda payload: (
                    payload.get("found") is True
                    and payload.get("showsTerminalSurface") is True
                    and f"% {ios_first_command_text}" in (payload.get("renderedOutput") or "")
                    and "/usr/local/bin/tailscale" in (payload.get("renderedOutput") or "")
                ),
                timeout=20,
            )
            ipad_after_command_payload = read_json_file(ipad_render_dump) or ipad_after_command_payload
            if ipad_after_command_payload.get("errorMessage"):
                raise RuntimeError(f"iPad render reported an error after first iOS command:\n{json.dumps(ipad_after_command_payload, indent=2)}")
            if ipad_after_command_payload.get("isInputSurfaceReady") is not True:
                raise RuntimeError(
                    f"iPad input surface stopped being ready after the first iOS command:\n{json.dumps(ipad_after_command_payload, indent=2)}"
                )

            ipad_second_command_request.write_text("go\n")
            wait_for_file(ipad_second_command_focused, timeout=20)
            send_simulator_hardware_text(ios_second_command_text)
            ipad_after_second_command_payload = wait_for_render_dump(
                ipad_render_dump,
                lambda payload: payload.get("sessionID") == render_session_id
                and payload.get("isOwner") is True
                and f"% {ios_second_command_text}" in payload.get("renderedText", "")
                and "__spaces_second_command__" in payload.get("renderedText", ""),
                timeout=20,
            )
            ipad_second_command_completed.write_text("done\n")
            wait_for_file(ipad_post_second_command_screenshot, timeout=20)
            wait_for_file(ipad_second_command_observed, timeout=20)
            assert_process_alive(bridge_process, "mobile bridge", bridge_stdout_path, bridge_stderr_path)
            mac_viewer_after_second_command_payload = wait_for_terminal_window_dump(
                spacese2e,
                env,
                render_session_id,
                mac_viewer_dump_path,
                viewer=None,
                predicate=lambda payload: (
                    payload.get("found") is True
                    and payload.get("showsTerminalSurface") is True
                    and f"% {ios_second_command_text}" in (payload.get("renderedOutput") or "")
                    and "__spaces_second_command__" in (payload.get("renderedOutput") or "")
                ),
                timeout=20,
            )
            ipad_after_second_command_payload = read_json_file(ipad_render_dump) or ipad_after_second_command_payload
            expected_after_ios_command_text = ipad_after_second_command_payload.get("renderedText", "")
            if not expected_after_ios_command_text:
                raise RuntimeError(
                    f"Unable to derive canonical post-iPad-command render text from iPad render dump:\n{json.dumps(ipad_after_second_command_payload, indent=2)}"
                )

            assert_render_output_sane("iPad after second iOS command", ipad_after_second_command_payload.get("renderedText", ""), bare_command_lines=("ls",))
            assert_exact_terminal_text("iPad after second iOS command", ipad_after_second_command_payload.get("renderedText", ""), expected_after_ios_command_text)
            if ipad_after_second_command_payload.get("errorMessage"):
                raise RuntimeError(f"iPad render reported an error after second iOS command:\n{json.dumps(ipad_after_second_command_payload, indent=2)}")
            if ipad_after_second_command_payload.get("isInputSurfaceReady") is not True:
                raise RuntimeError(
                    f"iPad input surface stopped being ready after the second iOS command:\n{json.dumps(ipad_after_second_command_payload, indent=2)}"
                )
            assert_render_output_sane(
                "Mac viewer after second iOS command", mac_viewer_after_second_command_payload.get("renderedOutput") or "", bare_command_lines=("ls",)
            )
            assert_exact_terminal_text(
                "Mac viewer after second iOS command", mac_viewer_after_second_command_payload.get("renderedOutput") or "", expected_after_ios_command_text
            )

            ipad_owner_client_id = wait_for_active_owner(temp_root, render_session_id, timeout=10, runtime_root=runtime_dir)
            show_result = subprocess.run(
                [str(spaces_cli), "terminal", "show", render_session_id],
                capture_output=True,
                text=True,
                env=env,
                check=True,
            )
            if "Requested owner terminal window" not in show_result.stdout:
                raise RuntimeError(f"Mac retakeover did not report success:\n{show_result.stdout}\n{show_result.stderr}")

            reclaimed_owner_client_id = wait_for_active_owner(
                temp_root, render_session_id, excluded_client_ids={ipad_owner_client_id}, timeout=20, runtime_root=runtime_dir
            )
            if reclaimed_owner_client_id == ipad_owner_client_id:
                raise RuntimeError("Mac retakeover did not transfer ownership away from iPad.")

            ipad_after_mac_retakeover_payload = wait_for_render_dump(
                ipad_render_dump,
                lambda payload: payload.get("sessionID") == render_session_id
                and payload.get("isOwner") is False
                and normalize_terminal_text(payload.get("renderedText", "")) == normalize_terminal_text(expected_after_ios_command_text),
                timeout=20,
            )
            mac_owner_after_retakeover_payload = wait_for_terminal_window_dump(
                spacese2e,
                env,
                render_session_id,
                mac_reclaimed_owner_dump_path,
                viewer=False,
                predicate=lambda payload: (
                    payload.get("found") is True
                    and payload.get("showsTerminalSurface") is True
                    and normalize_terminal_text(payload.get("renderedOutput") or "")
                    == normalize_terminal_text(expected_after_ios_command_text)
                ),
                timeout=20,
            )

            assert_render_output_sane(
                "iPad after Mac retakeover", ipad_after_mac_retakeover_payload.get("renderedText", ""), bare_command_lines=("ls",)
            )
            assert_exact_terminal_text(
                "iPad after Mac retakeover", ipad_after_mac_retakeover_payload.get("renderedText", ""), expected_after_ios_command_text
            )
            if ipad_after_mac_retakeover_payload.get("errorMessage"):
                raise RuntimeError(
                    f"iPad render reported an error after Mac retakeover:\n{json.dumps(ipad_after_mac_retakeover_payload, indent=2)}"
                )
            assert_render_output_sane(
                "Mac owner after retakeover", mac_owner_after_retakeover_payload.get("renderedOutput") or "", bare_command_lines=("ls",)
            )
            assert_exact_terminal_text(
                "Mac owner after retakeover", mac_owner_after_retakeover_payload.get("renderedOutput") or "", expected_after_ios_command_text
            )

            ipad_proceed_finish.write_text("done\n")
            wait_for_ios_ui_test(ui_test_process, ui_test_command, ui_test_stdout, ui_test_stderr)
            wait_for_file(ipad_post_mac_retakeover_screenshot, timeout=20)

            for event in collect_json_lines(ipad_event_log):
                message = event.get("errorMessage") or ""
                if (
                    "timed out" in message.lower()
                    or "temporarily unavailable" in message.lower()
                    or "connection refused" in message.lower()
                ):
                    raise RuntimeError(f"iPad render logged a transient timeout:\n{ipad_event_log.read_text()}")
                if (
                    event.get("isOwner") is True
                    and event.get("isConnecting") is True
                    and "README.md" in event.get("renderedText", "")
                ):
                    raise RuntimeError(f"iPad render reconnected after ownership takeover:\n{ipad_event_log.read_text()}")

            print(
                json.dumps(
                    {
                        "finalRenderSample": {
                            "sampledAt": iso_now(),
                            "expectedPreTakeoverText": expected_render_text,
                            "expectedAfterIOSCommandText": expected_after_ios_command_text,
                            "ipadAfterTakeover": ipad_payload,
                            "macViewerAfterTakeover": mac_viewer_payload,
                            "ipadAfterIOSCommand": ipad_after_command_payload,
                            "macViewerAfterIOSCommand": mac_viewer_after_command_payload,
                            "ipadAfterMacRetakeover": ipad_after_mac_retakeover_payload,
                            "macOwnerAfterRetakeover": mac_owner_after_retakeover_payload,
                            "ipadImmediateScreenshotPath": str(ipad_immediate_screenshot),
                            "ipadShortDelayScreenshotPath": str(ipad_short_delay_screenshot),
                            "ipadLongDelayScreenshotPath": str(ipad_long_delay_screenshot),
                            "ipadPostFirstCommandScreenshotPath": str(ipad_post_first_command_screenshot),
                            "ipadPostSecondCommandScreenshotPath": str(ipad_post_second_command_screenshot),
                            "ipadPostMacRetakeoverScreenshotPath": str(ipad_post_mac_retakeover_screenshot),
                        }
                    },
                    indent=2,
                    sort_keys=True,
                )
            )

        print(f"Mobile terminal client POC passed session={session_id} owner={reopened_owner_client_id} mobile={mobile_client['id']}")
        return 0
    except Exception:
        preserve_artifacts = True
        print(f"Preserving failure artifacts in {temp_root}", file=sys.stderr)
        raise
    finally:
        release_harness_lock()
        if stream is not None:
            try:
                stream.close()
            except Exception:
                pass
        if bridge_process is not None:
            bridge_process.terminate()
            try:
                bridge_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                bridge_process.kill()
        if bridge_stdout_handle is not None:
            bridge_stdout_handle.close()
        if bridge_stderr_handle is not None:
            bridge_stderr_handle.close()
        if ui_test_process is not None and ui_test_process.poll() is None:
            ui_test_process.terminate()
            try:
                ui_test_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                ui_test_process.kill()
        if app_process is not None:
            app_process.terminate()
            try:
                app_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                app_process.kill()
        if service_pid is not None:
            try:
                os.kill(service_pid, 15)
            except ProcessLookupError:
                pass
        if preserve_artifacts:
            print(f"Failure artifacts preserved at {temp_root}", file=sys.stderr)
        elif preserve_success_artifacts:
            print(f"Success artifacts preserved at {temp_root}", file=sys.stderr)
        else:
            shutil.rmtree(temp_root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
