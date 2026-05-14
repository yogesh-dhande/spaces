#!/usr/bin/env python3

import argparse
import json
import os
import re
import shutil
import socket
import statistics
import subprocess
import tempfile
import time
import uuid
from pathlib import Path


def percentile(values, pct):
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round((pct / 100) * (len(ordered) - 1))))
    return ordered[index]


def metric_summary(values):
    if not values:
        return "count=0"
    return (
        f"count={len(values)} min={min(values):.1f}ms avg={statistics.mean(values):.1f}ms "
        f"p95={percentile(values, 95):.1f}ms max={max(values):.1f}ms"
    )


def socket_path_for_session(spaces_root: Path, session_id: str) -> Path:
    seed = f"{spaces_root}|{session_id}".encode("utf-8")
    hash_value = 5381
    for byte in seed:
        hash_value = ((hash_value << 5) + hash_value + byte) & 0xFFFFFFFFFFFFFFFF
    return Path("/tmp/spaces-terminal-sockets") / f"{hash_value:016x}.sock"


def send_unix_request(socket_path: Path, request: dict) -> dict:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(5)
    client.connect(str(socket_path))
    payload = json.dumps(request).encode("utf-8")
    client.sendall(payload)
    client.shutdown(socket.SHUT_WR)
    response = bytearray()
    while True:
        chunk = client.recv(4096)
        if not chunk:
            break
        response.extend(chunk)
    client.close()
    return json.loads(response.decode("utf-8"))


def send_tcp_request(host: str, port: int, request: dict, simulated_rtt_ms: float = 0.0) -> dict:
    half_rtt = max(0.0, simulated_rtt_ms) / 2000.0
    if half_rtt:
        time.sleep(half_rtt)
    client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    client.settimeout(5)
    client.connect((host, port))
    payload = json.dumps(request).encode("utf-8")
    client.sendall(payload)
    client.shutdown(socket.SHUT_WR)
    response = bytearray()
    while True:
        chunk = client.recv(4096)
        if not chunk:
            break
        response.extend(chunk)
    client.close()
    if half_rtt:
        time.sleep(half_rtt)
    return json.loads(response.decode("utf-8"))


def timed_ms(fn):
    started = time.perf_counter_ns()
    result = fn()
    elapsed = (time.perf_counter_ns() - started) / 1_000_000
    return elapsed, result


def wait_for_session_ready(socket_path: Path, timeout: float = 10) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if socket_path.exists():
            try:
                response = send_unix_request(socket_path, {"command": "snapshot", "recentOutputLineCount": 10})
                if response.get("ok"):
                    return
            except Exception:
                pass
        time.sleep(0.05)
    raise RuntimeError("Timed out waiting for session readiness.")


def wait_for_output(send_request, needle: str, timeout: float = 10) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        response = send_request({"command": "snapshot", "recentOutputLineCount": 200})
        if response.get("ok") and needle in response["snapshot"]["recentOutput"]:
            return
        time.sleep(0.05)
    raise RuntimeError(f"Timed out waiting for output containing {needle!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--iterations", type=int, default=10)
    parser.add_argument(
        "--simulated-rtt-ms", type=str, default="0,20,80",
        help="Comma-separated artificial RTT values in milliseconds applied around TCP requests.",
    )
    args = parser.parse_args()
    simulated_rtts = [float(value) for value in args.simulated_rtt_ms.split(",") if value.strip()]

    repo_root = Path(__file__).resolve().parents[3]
    spaces_cli = Path(os.environ.get("SPACES_CLI", repo_root / "apps/macos/.build/debug/spaces"))
    temp_root = Path(tempfile.mkdtemp(prefix="spaces-terminal-tcp-profile."))
    db_path = temp_root / "spaces.db"
    env = os.environ | {"SPACES_DB_PATH": str(db_path)}
    auth_token = str(uuid.uuid4()).upper()

    fixture = (
        "python3 -u -c "
        "\"import sys; print('ready', flush=True); "
        "import itertools; "
        "[(print('echo:' + line.rstrip('\\\\n'), flush=True)) for line in sys.stdin]\""
    )

    proxy_process = None
    session_id = None
    try:
        result = subprocess.run(
            [str(spaces_cli), "terminal", "command", "--backend", "script-pty", "--command", fixture, "--title", "tcp-profile"],
            capture_output=True,
            text=True,
            env=env,
            check=True,
        )
        match = re.search(r"Started terminal session ([A-F0-9-]+)", result.stdout, re.IGNORECASE)
        if not match:
            raise RuntimeError(f"Unable to parse session id from:\n{result.stdout}")
        session_id = match.group(1)
        spaces_root = db_path.parent
        socket_path = socket_path_for_session(spaces_root, session_id)
        wait_for_session_ready(socket_path)

        proxy_process = subprocess.Popen(
            [
                str(spaces_cli), "terminal", "proxy", session_id, "--host", "127.0.0.1", "--port", "0", "--auth-token", auth_token,
            ],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        ready_line = proxy_process.stdout.readline().strip()
        match = re.search(r"host=([0-9.]+)\tport=(\d+)", ready_line)
        if not match:
            stderr = proxy_process.stderr.read()
            raise RuntimeError(f"Unable to parse proxy endpoint from:\n{ready_line}\n{stderr}")
        host = match.group(1)
        port = int(match.group(2))

        def unix_request(request):
            return send_unix_request(socket_path, request)

        owner_client = {
            "id": str(uuid.uuid4()).upper(),
            "kind": "remoteViewer",
            "identity": {"label": "mac-owner", "deviceName": "Mac", "networkAddress": "127.0.0.1"},
            "connectedAt": "2026-05-14T00:00:00Z",
            "disconnectedAt": None,
        }
        viewer_client = {
            "id": str(uuid.uuid4()).upper(),
            "kind": "remoteViewer",
            "identity": {"label": "iphone-viewer", "deviceName": "iPhone", "networkAddress": "10.0.0.24"},
            "connectedAt": "2026-05-14T00:00:00Z",
            "disconnectedAt": None,
        }
        response = send_tcp_request(host, port, {"authToken": auth_token, "command": "attach", "client": owner_client, "attachmentMode": "owner"})
        if not response.get("ok"):
            raise RuntimeError(f"Owner attach failed: {response}")
        response = send_tcp_request(host, port, {"authToken": auth_token, "command": "attach", "client": viewer_client, "attachmentMode": "viewer"})
        if not response.get("ok"):
            raise RuntimeError(f"Viewer attach failed: {response}")

        snapshot_unix = []
        output_size_unix = []
        chunk_unix = []
        for _ in range(args.iterations):
            elapsed, response = timed_ms(lambda: unix_request({"command": "snapshot", "recentOutputLineCount": 20}))
            if not response.get("ok"):
                raise RuntimeError(f"Unix snapshot failed: {response}")
            snapshot_unix.append(elapsed)

            elapsed, response = timed_ms(lambda: unix_request({"command": "output_size"}))
            if not response.get("ok"):
                raise RuntimeError(f"Unix output_size failed: {response}")
            output_size_unix.append(elapsed)
            output_offset = response.get("outputByteCount", 0)

            elapsed, response = timed_ms(
                lambda: unix_request({"command": "read_output_chunk", "offset": max(0, output_offset - 32), "maximumBytes": 32})
            )
            if not response.get("ok"):
                raise RuntimeError(f"Unix read_output_chunk failed: {response}")
            chunk_unix.append(elapsed)

        print("Terminal TCP proxy profile")
        print("")
        print(f"unix_snapshot: {metric_summary(snapshot_unix)}")
        print(f"unix_output_size: {metric_summary(output_size_unix)}")
        print(f"unix_read_output_chunk: {metric_summary(chunk_unix)}")

        for simulated_rtt_ms in simulated_rtts:
            def tcp_request(request):
                return send_tcp_request(host, port, {"authToken": auth_token, **request}, simulated_rtt_ms=simulated_rtt_ms)

            hello_tcp = []
            ping_tcp = []
            snapshot_tcp = []
            output_size_tcp = []
            chunk_tcp = []
            send_tcp = []
            send_echo_tcp = []
            takeover_tcp = []

            for index in range(args.iterations):
                elapsed, response = timed_ms(lambda: tcp_request({"command": "hello"}))
                if not response.get("ok"):
                    raise RuntimeError(f"TCP hello failed: {response}")
                hello_tcp.append(elapsed)

                elapsed, response = timed_ms(lambda: tcp_request({"command": "ping"}))
                if not response.get("ok"):
                    raise RuntimeError(f"TCP ping failed: {response}")
                ping_tcp.append(elapsed)

                elapsed, response = timed_ms(lambda: tcp_request({"command": "snapshot", "recentOutputLineCount": 20}))
                if not response.get("ok"):
                    raise RuntimeError(f"TCP snapshot failed: {response}")
                snapshot_tcp.append(elapsed)

                elapsed, response = timed_ms(lambda: tcp_request({"command": "output_size"}))
                if not response.get("ok"):
                    raise RuntimeError(f"TCP output_size failed: {response}")
                output_size_tcp.append(elapsed)
                output_offset = response.get("outputByteCount", 0)

                elapsed, response = timed_ms(
                    lambda: tcp_request({"command": "read_output_chunk", "offset": max(0, output_offset - 32), "maximumBytes": 32})
                )
                if not response.get("ok"):
                    raise RuntimeError(f"TCP read_output_chunk failed: {response}")
                chunk_tcp.append(elapsed)

                send_started = time.perf_counter_ns()
                response = tcp_request(
                    {"command": "send", "text": f"proxy-rtt{int(simulated_rtt_ms)}-{index}", "appendNewline": True, "clientID": owner_client["id"]}
                )
                send_elapsed = (time.perf_counter_ns() - send_started) / 1_000_000
                if not response.get("ok"):
                    raise RuntimeError(f"TCP send failed: {response}")
                send_tcp.append(send_elapsed)
                wait_for_output(tcp_request, f"echo:proxy-rtt{int(simulated_rtt_ms)}-{index}")
                send_echo_tcp.append((time.perf_counter_ns() - send_started) / 1_000_000)

            for _ in range(3):
                elapsed, response = timed_ms(lambda: tcp_request({"command": "takeover", "clientID": viewer_client["id"]}))
                if not response.get("ok"):
                    raise RuntimeError(f"TCP takeover to viewer failed: {response}")
                takeover_tcp.append(elapsed)
                elapsed, response = timed_ms(lambda: tcp_request({"command": "takeover", "clientID": owner_client["id"]}))
                if not response.get("ok"):
                    raise RuntimeError(f"TCP takeover to owner failed: {response}")
                takeover_tcp.append(elapsed)

            print("")
            print(f"simulated_rtt_ms={simulated_rtt_ms:.0f}")
            print(f"tcp_hello: {metric_summary(hello_tcp)}")
            print(f"tcp_ping: {metric_summary(ping_tcp)}")
            print(f"tcp_snapshot: {metric_summary(snapshot_tcp)}")
            print(f"tcp_output_size: {metric_summary(output_size_tcp)}")
            print(f"tcp_read_output_chunk: {metric_summary(chunk_tcp)}")
            print(f"tcp_control_send: {metric_summary(send_tcp)}")
            print(f"tcp_send_echo_roundtrip: {metric_summary(send_echo_tcp)}")
            print(f"tcp_control_takeover: {metric_summary(takeover_tcp)}")
        print("")
        print(f"session_id={session_id} iterations={args.iterations} proxy={host}:{port}")
        return 0
    finally:
        if proxy_process:
            proxy_process.terminate()
            try:
                proxy_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proxy_process.kill()
        if session_id:
            try:
                socket_path = socket_path_for_session(db_path.parent, session_id)
                send_unix_request(socket_path, {"command": "terminate"})
            except Exception:
                pass
        shutil.rmtree(temp_root, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
