#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "Usage: $0 <spacesd-path> <version> <output-dir>" >&2
  exit 64
fi

SPACESD="$1"
VERSION="$2"
OUTPUT_DIR="$3"
ARTIFACT_ID="spacesd-macos-universal"
ARCHIVE_NAME="$ARTIFACT_ID.tar.gz"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTYVT_LIB_DIR="${SPACES_GHOSTTY_VT_LIB_DIR:-$REPO_ROOT/apps/macos/.local/ghosttyvt/lib}"

[[ -x "$SPACESD" ]] || { echo "spacesd missing or not executable at $SPACESD" >&2; exit 1; }

shopt -s nullglob
ghostty_vt_dylibs=("$GHOSTTYVT_LIB_DIR"/libghostty-vt*.dylib)
shopt -u nullglob

binary_has_arch() {
  local archs="$1"
  local arch="$2"
  case " $archs " in
    *" $arch "* ) return 0 ;;
    * ) return 1 ;;
  esac
}

require_universal_macos_binary() {
  local binary_path="$1"
  local label="$2"
  local archs

  [[ -f "$binary_path" ]] || { echo "Missing $label at $binary_path" >&2; exit 1; }
  archs="$(lipo -archs "$binary_path" 2>/dev/null || true)"
  if ! binary_has_arch "$archs" arm64 || ! binary_has_arch "$archs" x86_64; then
    echo "$label must be universal arm64+x86_64, but found: ${archs:-unknown} ($binary_path)" >&2
    exit 1
  fi
}

is_universal_macos_binary() {
  local binary_path="$1"
  local archs

  [[ -f "$binary_path" ]] || return 1
  archs="$(lipo -archs "$binary_path" 2>/dev/null || true)"
  binary_has_arch "$archs" arm64 && binary_has_arch "$archs" x86_64
}

copy_or_build_universal_ghostty_vt_dylibs() {
  local destination_dir="$1"
  local source_dylib="$GHOSTTYVT_LIB_DIR/libghostty-vt.dylib"
  local real_source_dylib

  if [[ -e "$source_dylib" || -L "$source_dylib" ]]; then
    if real_source_dylib="$(realpath "$source_dylib" 2>/dev/null)" && is_universal_macos_binary "$real_source_dylib"; then
      cp -P "${ghostty_vt_dylibs[@]}" "$destination_dir/"
      require_universal_macos_binary "$destination_dir/$(basename "$real_source_dylib")" "packaged libghostty-vt dylib"
      return
    fi
  fi

  local universal_static="$GHOSTTYVT_LIB_DIR/ghostty-vt.xcframework/macos-arm64_x86_64/libghostty-vt.a"
  require_universal_macos_binary "$universal_static" "Ghostty VT static xcframework library"

  xcrun clang \
    -dynamiclib \
    -arch arm64 \
    -arch x86_64 \
    -mmacosx-version-min=14.0 \
    -install_name @rpath/libghostty-vt.dylib \
    -compatibility_version 0.1.0 \
    -current_version 0.1.0 \
    -o "$destination_dir/libghostty-vt.0.1.0.dylib" \
    -Wl,-all_load \
    "$universal_static"
  ln -s libghostty-vt.0.1.0.dylib "$destination_dir/libghostty-vt.0.dylib"
  ln -s libghostty-vt.0.dylib "$destination_dir/libghostty-vt.dylib"
  require_universal_macos_binary "$destination_dir/libghostty-vt.0.1.0.dylib" "packaged libghostty-vt dylib"
}

write_spaces_wrapper() {
  local destination="$1"
  cat > "$destination" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: spaces agent signal --workspace <id> --session <terminal-session-id> <init|start|waiting|done|exit>" >&2
}

if [[ "${1:-}" != "agent" || "${2:-}" != "signal" ]]; then
    usage
    exit 64
fi
shift 2

workspace_id=""
session_id=""
event_type=""
while [[ "$#" -gt 0 ]]; do
    case "${1}" in
        --workspace)
            [[ "$#" -ge 2 ]] || { echo "missing --workspace value" >&2; exit 64; }
            workspace_id="${2}"
            shift 2
            ;;
        --workspace=*)
            workspace_id="${1#--workspace=}"
            shift
            ;;
        --session)
            [[ "$#" -ge 2 ]] || { echo "missing --session value" >&2; exit 64; }
            session_id="${2}"
            shift 2
            ;;
        --session=*)
            session_id="${1#--session=}"
            shift
            ;;
        init|start|waiting|done|exit)
            [[ -z "$event_type" ]] || { echo "duplicate event" >&2; exit 64; }
            event_type="${1}"
            shift
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

[[ -n "$workspace_id" && -n "$session_id" && -n "$event_type" ]] || {
    usage
    exit 64
}

workspace_path="${SPACES_WORKSPACE_DIR:-}"

python3 - "$event_type" "$workspace_id" "$session_id" "$workspace_path" <<'PY'
import datetime
import json
import os
import socket
import sys
import uuid

event_type = sys.argv[1].strip()
workspace_id = sys.argv[2].strip()
session_id = sys.argv[3].strip()
workspace_arg = sys.argv[4].strip()
allowed = {"init", "start", "waiting", "done", "exit"}
if event_type not in allowed:
    print(f"unsupported agent signal event: {event_type}", file=sys.stderr)
    sys.exit(64)

def socket_path():
    override = os.environ.get("SPACESD_SERVICE_SOCKET", "").strip()
    if override:
        return override
    runtime_root = os.environ.get("SPACES_RUNTIME_DIR", "").strip()
    if not runtime_root:
        raise RuntimeError("SPACES_RUNTIME_DIR is required for remote spaces agent signal.")
    terminal_root = os.path.abspath(os.path.join(runtime_root, "terminal"))
    value = 5381
    for byte in terminal_root.encode("utf-8"):
        value = (((value << 5) + value) + byte) & 0xFFFFFFFFFFFFFFFF
    return f"/tmp/spaces-terminal-sockets/service-{value:016x}.sock"

def optional_env(name):
    value = os.environ.get(name, "").strip()
    return value or None

created_at = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
workspace_path = workspace_arg or optional_env("SPACES_WORKSPACE_DIR") or os.getcwd()
event = {
    "id": str(uuid.uuid4()),
    "sessionID": session_id,
    "workspaceID": workspace_id,
    "workspacePath": workspace_path,
    "type": event_type,
    "provider": "spaces",
    "terminalTrackingID": session_id,
    "terminalNativeID": session_id,
    "codexThreadID": optional_env("CODEX_THREAD_ID"),
    "environmentKeys": sorted(os.environ.keys()),
    "createdAt": created_at,
}
request = {"command": "agentSignal", "sessionID": session_id, "agentSignal": event}

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(5)
try:
    sock.connect(socket_path())
    sock.sendall(json.dumps(request, separators=(",", ":")).encode("utf-8") + b"\n")
    sock.shutdown(socket.SHUT_WR)
    data = bytearray()
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data.extend(chunk)
        if b"\n" in chunk:
            break
finally:
    sock.close()

line = bytes(data).split(b"\n", 1)[0]
response = json.loads(line.decode("utf-8"))
if not response.get("ok"):
    print(response.get("message") or "remote spacesd rejected agent signal", file=sys.stderr)
    sys.exit(1)

print(f"Agent {event_type}: queued remote signal\tsession={session_id}")
PY
EOF
  chmod +x "$destination"
}

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
staging_parent="$OUTPUT_DIR/.staging-macos"
staging_root="$staging_parent/$ARTIFACT_ID"
rm -rf "$staging_root"
mkdir -p "$staging_root/bin"

write_spaces_wrapper "$staging_root/bin/spaces"
cp "$SPACESD" "$staging_root/bin/spacesd"
chmod +x "$staging_root/bin/spaces" "$staging_root/bin/spacesd"
copy_or_build_universal_ghostty_vt_dylibs "$staging_root/bin"

python3 - "$staging_root/manifest.json" "$ARTIFACT_ID" "$VERSION" "$ARCHIVE_NAME" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
artifact_id, version, archive_name = sys.argv[2:5]
manifest = {
    "schema_version": 1,
    "artifact_id": artifact_id,
    "version": version,
    "platform": "macos",
    "architecture": "universal",
    "archive_name": archive_name,
    "cli": "bin/spaces",
    "executable": "bin/spacesd",
    "vt_library": "bin/libghostty-vt.dylib",
}
path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

(
  cd "$staging_root"
  find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort | sed 's#^\./##' | xargs shasum -a 256 > SHA256SUMS
)

rm -f "$OUTPUT_DIR/$ARCHIVE_NAME" "$OUTPUT_DIR/$ARCHIVE_NAME.sha256"
(
  cd "$staging_parent"
  tar -czf "$OUTPUT_DIR/$ARCHIVE_NAME" "$ARTIFACT_ID"
)
(cd "$OUTPUT_DIR" && shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256")
echo "Wrote $OUTPUT_DIR/$ARCHIVE_NAME"
