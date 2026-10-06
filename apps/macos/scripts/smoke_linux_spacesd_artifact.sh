#!/usr/bin/env bash
# Usage: apps/macos/scripts/smoke_linux_spacesd_artifact.sh <path to spacesd-linux-<arch>.tar.gz>
#
# Proves a built Linux daemon archive works end to end: checksums, the bundled binaries load,
# the daemon starts and prints its certificate fingerprint, a PTY session runs, agent signals and
# send/tail work, a pinned-TLS pairing round trip succeeds, and a reinstall through the bundled
# install.sh hands off to the running daemon in place without losing its sessions.
#
# Runs as any user on any glibc 2.38+ Linux that has bash, python3, openssl, tar, gzip and
# coreutils. It needs no systemd: install.sh's loginctl and systemctl calls are shimmed.
set -euo pipefail

die() {
    echo "$*" >&2
    exit 1
}

[[ "$#" -eq 1 ]] || die "usage: smoke_linux_spacesd_artifact.sh <path to spacesd-linux-<arch>.tar.gz>"
archive_path="$1"
[[ -f "$archive_path" ]] || die "artifact archive missing at $archive_path"
archive_path="$(cd "$(dirname "$archive_path")" && pwd)/$(basename "$archive_path")"
# The archive unpacks to a directory named after itself: spacesd-linux-<arch>.tar.gz -> spacesd-linux-<arch>/.
ARTIFACT_ID="$(basename "$archive_path")"
ARTIFACT_ID="${ARTIFACT_ID%.tar.gz}"

smoke_artifact() {
    local smoke_root
    smoke_root="$(mktemp -d)"
    tar -xzf "$archive_path" -C "$smoke_root"
    (
        cd "$smoke_root/$ARTIFACT_ID"
        sha256sum -c SHA256SUMS
        test -x bin/spaces
        test -x bin/spacesd
        test -x bin/spacesd-bin
        test -x bin/spaces-bin
        test -x install.sh
        bin/spaces --help >/tmp/spaces-linux-helper-smoke.log
        ldd bin/spacesd-bin >/dev/null
        ldd bin/spaces-bin >/dev/null
        timeout 20s env SPACES_DB_PATH="$smoke_root/profile/spaces.db" SPACESD_PRINT_CERTIFICATE_FINGERPRINT=1 bin/spacesd | grep -q '^SHA256:'
        mkdir -p "$smoke_root/profile/runtime" "$smoke_root/work" "$smoke_root/reinstall-home/.spaces/bin"
        ln -s "$PWD/bin/spacesd" "$smoke_root/reinstall-home/.spaces/bin/spacesd"
        env SPACES_DB_PATH="$smoke_root/profile/spaces.db" SPACES_RUNTIME_DIR="$smoke_root/profile/runtime" \
            SPACES_DEVICE_API_HOST=127.0.0.1 SPACES_DEVICE_API_PORT=0 \
            "$smoke_root/reinstall-home/.spaces/bin/spacesd" >"$smoke_root/spacesd.log" 2>&1 </dev/null &
        local daemon_pid=$!
        trap 'kill "$daemon_pid" 2>/dev/null || true; wait "$daemon_pid" 2>/dev/null || true' EXIT
        python3 - "$smoke_root" <<'PY'
import json
import os
import socket
import sys
import time
import datetime
import uuid

root = sys.argv[1]
runtime = os.path.join(root, "profile", "runtime")
work = os.path.join(root, "work")

def service_socket_path():
    terminal_root = os.path.realpath(os.path.join(runtime, "terminal"))
    value = 5381
    for byte in terminal_root.encode("utf-8"):
        value = (((value << 5) + value) + byte) & 0xFFFFFFFFFFFFFFFF
    return f"/tmp/spaces-sockets-{os.getuid()}/service-{value:016x}.sock"

def request(payload, timeout=10):
    deadline = time.time() + timeout
    path = service_socket_path()
    while True:
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            sock.connect(path)
            break
        except OSError:
            if time.time() > deadline:
                raise
            time.sleep(0.1)
    with sock:
        sock.sendall(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
        sock.shutdown(socket.SHUT_WR)
        data = bytearray()
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data.extend(chunk)
    return json.loads(data.decode("utf-8"))

response = request({
    "command": {
        "create": {
            "launchConfiguration": {
                "sessionID": "linux-artifact-smoke",
                "backend": "ghostty-embedded",
                "lifetimePolicy": "persistent",
                "title": "artifact smoke",
                "workingDirectory": work,
                "shell": "/bin/bash",
                "command": "echo artifact-smoke; sleep 600",
                "createdAt": "2026-06-11T00:00:00.000Z",
                "workspaceID": "artifact-workspace",
                "kind": "process",
            },
        },
    },
})
if not response.get("ok"):
    raise SystemExit(response)

created_at = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
response = request({
    "command": {
        "agentSignal": {
            "event": {
                "id": str(uuid.uuid4()),
                "sessionID": "linux-artifact-smoke",
                "workspaceID": "artifact-workspace",
                "workspacePath": work,
                "type": "waiting",
                "provider": "spaces",
                "terminalTrackingID": "linux-artifact-smoke",
                "terminalNativeID": "linux-artifact-smoke",
                "environmentKeys": [],
                "createdAt": created_at,
            },
        },
    },
})
if not response.get("ok"):
    raise SystemExit(response)
PY
        bin/spaces signal waiting >/tmp/spaces-linux-signal-legacy-smoke.log 2>&1 && exit 1 || test "$?" -eq 64
        python3 - "$smoke_root" <<'PY'
import json
import os
import socket
import sys

root = sys.argv[1]
runtime = os.path.join(root, "profile", "runtime")

terminal_root = os.path.realpath(os.path.join(runtime, "terminal"))
value = 5381
for byte in terminal_root.encode("utf-8"):
    value = (((value << 5) + value) + byte) & 0xFFFFFFFFFFFFFFFF
path = f"/tmp/spaces-sockets-{os.getuid()}/service-{value:016x}.sock"

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(10)
with sock:
    sock.connect(path)
    sock.sendall(json.dumps({"command": {"state": {"sessionID": "linux-artifact-smoke"}}}).encode("utf-8"))
    sock.shutdown(socket.SHUT_WR)
    data = bytearray()
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            break
        data.extend(chunk)

response = json.loads(data.decode("utf-8"))
signals = response.get("agentSignals") or []
if not response.get("ok") or not any(signal.get("type") == "waiting" for signal in signals):
    raise SystemExit(response)
PY
        # Pinned-TLS gate: open a pairing window through the shipped CLI, pair a loopback
        # Device API client against the daemon's pinned certificate fingerprint, and issue one
        # authed request over that channel. This is the only automated Linux TLS round-trip.
        env SPACES_DB_PATH="$smoke_root/profile/spaces.db" SPACES_RUNTIME_DIR="$smoke_root/profile/runtime" \
            SPACES_DEVICE_API_HOST=127.0.0.1 SPACES_DEVICE_API_PORT=0 \
            bin/spaces device pair --json >"$smoke_root/pairing-window.json"
        python3 - "$smoke_root/pairing-window.json" <<'PY'
import hashlib
import json
import socket
import ssl
import sys

pairing = json.load(open(sys.argv[1]))
# A pairing window advertises an ordered candidate address list. This smoke run binds the
# Device API to a concrete host, which must collapse to exactly that one candidate, a
# wildcard bind is what produces LAN-then-tailnet fallbacks, and there is none here.
hosts = pairing["hosts"]
if hosts != ["127.0.0.1"]:
    raise SystemExit(f"expected the bound host as the only pairing candidate, got {hosts!r}")
host = hosts[0]
port = int(pairing["port"])
fingerprint = pairing["certificateFingerprint"]
if not fingerprint.startswith("SHA256:"):
    raise SystemExit(f"unexpected certificate fingerprint format: {fingerprint!r}")
expected = fingerprint.split(":", 1)[1].strip().lower()

context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE
context.minimum_version = ssl.TLSVersion.TLSv1_2

def request(body):
    with socket.create_connection((host, port), timeout=10) as raw:
        with context.wrap_socket(raw, server_hostname=host) as tls:
            # Pin before any application byte: the daemon's leaf certificate must match the
            # fingerprint delivered in the pairing window.
            actual = hashlib.sha256(tls.getpeercert(binary_form=True)).hexdigest()
            if actual != expected:
                raise SystemExit(f"certificate fingerprint mismatch: expected {expected} got {actual}")
            tls.sendall(json.dumps(body, separators=(",", ":")).encode("utf-8") + b"\n")
            data = bytearray()
            while b"\n" not in data:
                chunk = tls.recv(65536)
                if not chunk:
                    break
                data.extend(chunk)
    return json.loads(bytes(data).split(b"\n", 1)[0].decode("utf-8"))

client_app = {
    "installationID": "linux-artifact-smoke",
    "bundleID": "dev.usespaces.spacesmobile",
    "platform": "ios",
    "deviceName": "Linux Artifact Smoke",
    "appVersion": "1.0",
}
paired = request({
    "clientApp": client_app,
    "command": {
        "pair": {
            "pairingCode": pairing["pairingCode"],
            "pairingNonce": pairing["pairingNonce"],
            # Version-gated pairing: echo the daemon's advertised wire-protocol version so the pair
            # request matches and is not rejected before the code is validated.
            "clientProtocolVersion": pairing["protocolVersion"],
        }
    },
})
auth_token = ((paired.get("result") or {}).get("issuedAuthToken") or {}).get("authToken")
if not paired.get("ok") or not auth_token:
    raise SystemExit(paired)

overview = request({
    "authToken": auth_token,
    "clientApp": client_app,
    "command": {"overview": {}},
})
if not overview.get("ok") or "overview" not in (overview.get("result") or {}):
    raise SystemExit(overview)

# Agent send/tail round trip against the smoke session: one-shot input needs no
# attach/owner handshake, and the rendered tail shows both the session's startup
# echo and the PTY echo of the sent text.
sent = request({
    "authToken": auth_token,
    "clientApp": client_app,
    "command": {"sendTerminalInput": {"sessionID": "linux-artifact-smoke", "text": "agent-roundtrip-marker", "appendNewline": True}},
})
if not sent.get("ok"):
    raise SystemExit(sent)

import time as _time
deadline = _time.time() + 15
while True:
    tailed = request({
        "authToken": auth_token,
        "clientApp": client_app,
        "command": {"tailTerminalOutput": {"sessionID": "linux-artifact-smoke", "lines": 50}},
    })
    text = ((tailed.get("result") or {}).get("terminalOutput") or {}).get("text") or ""
    if tailed.get("ok") and "artifact-smoke" in text and "agent-roundtrip-marker" in text:
        break
    if _time.time() > deadline:
        raise SystemExit(tailed)
    _time.sleep(0.5)
PY

        # --- Exec-in-place handoff leg -----------------------------------------------------
        # A Linux reinstall of the SAME artifact must poke the already-running daemon instead of
        # restarting it: spacesd quiesces its sessions and execs its own staged binary in place at
        # the same pid, then resumes them. Drive this through the bundled install.sh so the poke
        # branch added to write_linux_install_script runs for real. install.sh's
        # ensure_user_linger/systemctl steps talk to a real user systemd + logind session that this
        # Docker smoke sandbox does not run, so loginctl/systemctl are shimmed on PATH for this leg.
        # Docker Desktop's amd64 Rosetta runner also exposes /proc/<pid>/exe as the translator rather
        # than the guest executable. Its stat shim reports the staged identity only after the real
        # daemon log proves the handoff resumed; native Linux still uses the real /proc identity.
        echo "==> smoke: reinstall handoff (install.sh apply-update poke)"
        terminal_child_pid="$(python3 - "$smoke_root" <<'PY'
import os
import sqlite3
import sys

root = sys.argv[1]
conn = sqlite3.connect(os.path.join(root, "profile", "spaces.db"))
row = conn.execute(
    "SELECT child_pid FROM terminal_runtime_states WHERE session_id = ?", ("linux-artifact-smoke",)
).fetchone()
conn.close()
if not row or row[0] is None:
    raise SystemExit("no child_pid recorded for session linux-artifact-smoke")
print(row[0])
PY
)"
        kill -0 "$daemon_pid"
        kill -0 "$terminal_child_pid"

        install_shim_dir="$smoke_root/install-shim"
        mkdir -p "$install_shim_dir"
        cat > "$install_shim_dir/loginctl" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
    *"-p Linger --value"*) echo "yes" ;;
esac
exit 0
SHIM
        cat > "$install_shim_dir/systemctl" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
    *"show spacesd.service --property MainPID --value"*) echo "${SPACES_SMOKE_DAEMON_PID:-0}" ;;
esac
exit 0
SHIM
        cat > "$install_shim_dir/stat" <<'SHIM'
#!/usr/bin/env bash
proc_executable="/proc/${SPACES_SMOKE_DAEMON_PID:-0}/exe"
last_argument="${!#}"
if [[ "$last_argument" == "$proc_executable" ]] \
    && [[ "$(readlink "$proc_executable" 2>/dev/null || true)" == "/run/rosetta/rosetta" ]] \
    && grep -q "handoff_resume generation=1" "${SPACES_SMOKE_DAEMON_LOG:?}"; then
    staged_wrapper="$(readlink -f "$HOME/.spaces/bin/spacesd")"
    arguments=("$@")
    arguments[$# - 1]="$(dirname "$staged_wrapper")/spacesd-bin"
    exec /usr/bin/stat "${arguments[@]}"
fi
exec /usr/bin/stat "$@"
SHIM
        chmod +x "$install_shim_dir/loginctl" "$install_shim_dir/systemctl" "$install_shim_dir/stat"
        # SPACES_DB_PATH/SPACES_RUNTIME_DIR here are for the `spaces` CLI install.sh invokes, not for
        # install.sh itself: the installer ignores them entirely and lays out the installed profile,
        # while the CLI it runs needs them to reach the smoke daemon's own profile.
        if ! PATH="$install_shim_dir:$PATH" HOME="$smoke_root/reinstall-home" \
            SPACES_SMOKE_DAEMON_PID="$daemon_pid" \
            SPACES_SMOKE_DAEMON_LOG="$smoke_root/spacesd.log" \
            SPACES_DB_PATH="$smoke_root/profile/spaces.db" SPACES_RUNTIME_DIR="$smoke_root/profile/runtime" \
            ./install.sh >"$smoke_root/reinstall.log" 2>&1; then
            echo "install.sh reinstall failed" >&2
            cat "$smoke_root/reinstall.log" >&2
            exit 1
        fi

        if ! kill -0 "$daemon_pid" 2>/dev/null; then
            echo "daemon pid $daemon_pid vanished after reinstall; exec-in-place must preserve the pid" >&2
            cat "$smoke_root/reinstall.log" >&2
            cat "$smoke_root/spacesd.log" >&2
            exit 1
        fi
        if ! kill -0 "$terminal_child_pid" 2>/dev/null; then
            echo "terminal child pid $terminal_child_pid vanished after reinstall; the pre-existing session must survive" >&2
            exit 1
        fi
        # The poke responds before the daemon acts (respond-then-act), so the handoff (grace sleep,
        # preflight child, quiesce, exec, resume) completes a few seconds after install.sh returns.
        # Wait for the resume marker instead of racing it.
        handoff_resume_deadline=$((SECONDS + 20))
        until grep -q "handoff_resume generation=1" "$smoke_root/spacesd.log"; do
            if [ "$SECONDS" -ge "$handoff_resume_deadline" ]; then
                echo "expected 'handoff_resume generation=1' in spacesd.log within 20s of reinstall" >&2
                cat "$smoke_root/spacesd.log" >&2
                exit 1
            fi
            sleep 0.5
        done
        if ! kill -0 "$daemon_pid" 2>/dev/null; then
            echo "daemon pid $daemon_pid vanished across the handoff; exec-in-place must preserve the pid" >&2
            cat "$smoke_root/spacesd.log" >&2
            exit 1
        fi

        env SPACES_DB_PATH="$smoke_root/profile/spaces.db" SPACES_RUNTIME_DIR="$smoke_root/profile/runtime" \
            bin/spaces terminal list | grep -q '^linux-artifact-smoke\b'

        env SPACES_DB_PATH="$smoke_root/profile/spaces.db" SPACES_RUNTIME_DIR="$smoke_root/profile/runtime" \
            bin/spaces terminal send text linux-artifact-smoke post-handoff-marker --submit >/dev/null

        post_handoff_deadline=$((SECONDS + 15))
        until env SPACES_DB_PATH="$smoke_root/profile/spaces.db" SPACES_RUNTIME_DIR="$smoke_root/profile/runtime" \
            bin/spaces terminal tail linux-artifact-smoke --lines 50 | grep -q "post-handoff-marker"; do
            if [ "$SECONDS" -ge "$post_handoff_deadline" ]; then
                echo "post-handoff send/tail marker never appeared" >&2
                exit 1
            fi
            sleep 0.5
        done
        echo "==> smoke: reinstall handoff OK (daemon pid $daemon_pid unchanged, session and child $terminal_child_pid survived)"
    )
    rm -rf "$smoke_root"
}

smoke_artifact
