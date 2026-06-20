#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
APP_VERSION_SWIFT="$APP_ROOT/Sources/workspacecore/AppVersion.swift"
SUBMODULE_PATH="apps/macos/vendor/ghostty"
GHOSTTY_SOURCE_ROOT="$REPO_ROOT/$SUBMODULE_PATH"
GHOSTTYVT_ROOT="$APP_ROOT/.local/ghosttyvt"
GHOSTTYVT_INCLUDE_ROOT="$GHOSTTYVT_ROOT/include"
GHOSTTYVT_LIB_ROOT="$GHOSTTYVT_ROOT/lib"

ZIG_VERSION="0.15.2"
GHOSTTY_BUILD_OPTIMIZE="${SPACES_GHOSTTY_BUILD_OPTIMIZE:-ReleaseFast}"
host_arch="$(uname -m)"
case "$host_arch" in
    x86_64|amd64) DEFAULT_ARTIFACT_ARCH="x86_64" ;;
    aarch64|arm64) DEFAULT_ARTIFACT_ARCH="arm64" ;;
    *) DEFAULT_ARTIFACT_ARCH="$host_arch" ;;
esac
ARTIFACT_ARCH="${SPACES_LINUX_ARTIFACT_ARCH:-$DEFAULT_ARTIFACT_ARCH}"
ARTIFACT_ID="spacesd-ubuntu-24.04-$ARTIFACT_ARCH"
DEFAULT_ARTIFACT_VERSION="$(sed -nE 's/.*public static let short = "([^"]+)".*/\1/p' "$APP_VERSION_SWIFT" | head -n 1)"
ARTIFACT_VERSION="${SPACES_ARTIFACT_VERSION:-${DEFAULT_ARTIFACT_VERSION:-dev}}"
OUTPUT_DIR="$REPO_ROOT/dist/linux"
BUILD_CONFIGURATION="release"
BUILD_GHOSTTY_VT=1
SMOKE=1

usage() {
    cat <<'EOF'
Usage: apps/macos/scripts/build_linux_spacesd_artifact.sh [--output-dir DIR] [--debug] [--arch x86_64|arm64] [--skip-ghostty-vt-build] [--skip-smoke]

Builds the Ubuntu 24.04 spacesd device artifact for the current host architecture. The archive contains:
  spacesd-ubuntu-24.04-<arch>/bin/spaces
  spacesd-ubuntu-24.04-<arch>/bin/spacesd
  spacesd-ubuntu-24.04-<arch>/bin/spacesd-bin
  spacesd-ubuntu-24.04-<arch>/bin/libghostty-vt.so*
  spacesd-ubuntu-24.04-<arch>/lib/libswift*.so and related Swift runtime libraries
  spacesd-ubuntu-24.04-<arch>/install.sh
  spacesd-ubuntu-24.04-<arch>/manifest.json
  spacesd-ubuntu-24.04-<arch>/SHA256SUMS
EOF
}

die() {
    echo "$*" >&2
    exit 1
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --output-dir)
            [[ "$#" -ge 2 ]] || die "--output-dir requires a directory"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --debug)
            BUILD_CONFIGURATION="debug"
            shift
            ;;
        --arch)
            [[ "$#" -ge 2 ]] || die "--arch requires x86_64 or arm64"
            ARTIFACT_ARCH="$2"
            ARTIFACT_ID="spacesd-ubuntu-24.04-$ARTIFACT_ARCH"
            shift 2
            ;;
        --skip-ghostty-vt-build)
            BUILD_GHOSTTY_VT=0
            shift
            ;;
        --skip-smoke)
            SMOKE=0
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown build_linux_spacesd_artifact.sh argument: $1"
            ;;
    esac
done

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_command() {
    command_exists "$1" || die "required command not found: $1"
}

require_linux_supported_arch() {
    [[ "$(uname -s)" == "Linux" ]] || die "Linux spacesd artifacts must be built on Linux"
    local machine
    machine="$(uname -m)"
    case "$ARTIFACT_ARCH:$machine" in
        x86_64:x86_64|x86_64:amd64|arm64:aarch64|arm64:arm64) ;;
        *) die "Linux spacesd $ARTIFACT_ARCH artifacts must be built on matching Linux architecture; current machine is $machine" ;;
    esac
}

resolve_ghostty_sha() {
    if [[ -n "${SPACES_GHOSTTY_SHA:-}" ]]; then
        echo "$SPACES_GHOSTTY_SHA"
        return
    fi
    if git -C "$GHOSTTY_SOURCE_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "$GHOSTTY_SOURCE_ROOT" rev-parse HEAD
        return
    fi
    if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "$REPO_ROOT" ls-files -s -- "$SUBMODULE_PATH" | awk '$1 == "160000" { print $2; exit }'
        return
    fi
    echo "unknown"
}

ensure_ghostty_submodule() {
    if [[ -f "$GHOSTTY_SOURCE_ROOT/build.zig.zon" ]]; then
        return
    fi
    if git -C "$GHOSTTY_SOURCE_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        return
    fi
    echo "==> Initializing Ghostty submodule"
    git -C "$REPO_ROOT" submodule update --init --recursive -- "$SUBMODULE_PATH"
}

ghostty_dirty_state() {
    if ! git -C "$GHOSTTY_SOURCE_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        echo "false"
        return
    fi
    if [[ -n "$(git -C "$GHOSTTY_SOURCE_ROOT" status --porcelain)" ]]; then
        echo "true"
    else
        echo "false"
    fi
}

ghostty_app_version() {
    local version_line
    version_line="$(grep -m1 '\.version = ' "$GHOSTTY_SOURCE_ROOT/build.zig.zon" || true)"
    local app_version
    app_version="$(sed -E 's/.*"([^"]+)".*/\1/' <<<"$version_line")"
    if [[ -z "$app_version" || "$app_version" == "$version_line" ]]; then
        die "failed to determine Ghostty version string from $GHOSTTY_SOURCE_ROOT/build.zig.zon"
    fi
    echo "$app_version"
}

ensure_zig() {
    local zig_arch
    case "$ARTIFACT_ARCH" in
        x86_64) zig_arch="x86_64" ;;
        arm64) zig_arch="aarch64" ;;
        *) die "unsupported Linux spacesd artifact architecture: $ARTIFACT_ARCH" ;;
    esac
    local archive_name="zig-$zig_arch-linux-$ZIG_VERSION"
    local toolchain_root="$APP_ROOT/.local/linux-toolchain"
    local zig_install_root="$toolchain_root/$archive_name"
    local zig_bin="$zig_install_root/zig"

    if [[ ! -x "$zig_bin" ]]; then
        require_command curl
        require_command tar
        echo "==> Downloading Zig $ZIG_VERSION for Linux spacesd artifacts" >&2
        local tmp_dir
        tmp_dir="$(mktemp -d)"
        local archive="$archive_name.tar.xz"
        curl -fL "https://ziglang.org/download/$ZIG_VERSION/$archive" -o "$tmp_dir/$archive"
        mkdir -p "$toolchain_root"
        tar -xJf "$tmp_dir/$archive" -C "$toolchain_root"
        rm -rf "$tmp_dir"
    else
        echo "==> Zig $ZIG_VERSION already present at $zig_bin" >&2
    fi

    echo "$zig_bin"
}

build_ghostty_vt() {
    ensure_ghostty_submodule
    local dirty
    dirty="$(ghostty_dirty_state)"
    if [[ "$dirty" == "true" && "${SPACES_LINUX_ALLOW_DIRTY_GHOSTTY:-0}" != "1" ]]; then
        die "Ghostty submodule has local modifications; commit them before building Linux spacesd artifacts"
    fi

    local zig_bin
    zig_bin="$(ensure_zig)"
    local app_version
    app_version="$(ghostty_app_version)"

    echo "==> Building Linux libghostty-vt from $GHOSTTY_SOURCE_ROOT"
    (
        cd "$GHOSTTY_SOURCE_ROOT"
        "$zig_bin" build -Doptimize="$GHOSTTY_BUILD_OPTIMIZE" -Demit-lib-vt=true -Dversion-string="$app_version"
    )
}

stage_ghostty_vt_development_artifacts() {
    ensure_ghostty_submodule
    local source_include="$GHOSTTY_SOURCE_ROOT/zig-out/include"
    local source_lib="$GHOSTTY_SOURCE_ROOT/zig-out/lib"
    [[ -f "$source_include/ghostty/vt.h" ]] || die "libghostty-vt headers missing at $source_include"
    [[ -d "$source_lib" ]] || die "libghostty-vt library directory missing at $source_lib"
    shopt -s nullglob
    local libraries=("$source_lib"/libghostty-vt.so*)
    shopt -u nullglob
    [[ "${#libraries[@]}" -gt 0 ]] || die "libghostty-vt.so output missing under $source_lib"

    rm -rf "$GHOSTTYVT_INCLUDE_ROOT" "$GHOSTTYVT_LIB_ROOT"
    mkdir -p "$GHOSTTYVT_ROOT"
    cp -a "$source_include" "$GHOSTTYVT_INCLUDE_ROOT"
    cp -a "$source_lib" "$GHOSTTYVT_LIB_ROOT"
}

swift_build_flags() {
    if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
        printf -- "-c release"
    else
        printf -- ""
    fi
}

build_spaces_products() {
    require_command swift
    require_command pkg-config
    echo "==> Building Linux spacesd ($BUILD_CONFIGURATION)"
    local flags
    flags="$(swift_build_flags)"
    # shellcheck disable=SC2086
    swift build \
        --package-path "$APP_ROOT" \
        --product spacesd \
        --disable-sandbox \
        --build-path "${SPACES_LINUX_SWIFT_BUILD_PATH:-$APP_ROOT/.build/linux}" \
        --cache-path "${SPACES_LINUX_SWIFT_CACHE_PATH:-$APP_ROOT/.build/linux-spm-cache}" \
        --config-path "${SPACES_LINUX_SWIFT_CONFIG_PATH:-$APP_ROOT/.build/linux-spm-config}" \
        --security-path "${SPACES_LINUX_SWIFT_SECURITY_PATH:-$APP_ROOT/.build/linux-spm-security}" \
        $flags
    echo "==> Building Linux spaces CLI ($BUILD_CONFIGURATION)"
    # shellcheck disable=SC2086
    swift build \
        --package-path "$APP_ROOT" \
        --product spaces \
        --disable-sandbox \
        --build-path "${SPACES_LINUX_SWIFT_BUILD_PATH:-$APP_ROOT/.build/linux}" \
        --cache-path "${SPACES_LINUX_SWIFT_CACHE_PATH:-$APP_ROOT/.build/linux-spm-cache}" \
        --config-path "${SPACES_LINUX_SWIFT_CONFIG_PATH:-$APP_ROOT/.build/linux-spm-config}" \
        --security-path "${SPACES_LINUX_SWIFT_SECURITY_PATH:-$APP_ROOT/.build/linux-spm-security}" \
        $flags
}

swift_product_dir() {
    local build_root="${SPACES_LINUX_SWIFT_BUILD_PATH:-$APP_ROOT/.build/linux}"
    if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
        printf "%s/release\n" "$build_root"
    else
        printf "%s/debug\n" "$build_root"
    fi
}

copy_ghostty_vt_libraries() {
    local destination_bin="$1"
    local source_lib_dir="$GHOSTTYVT_LIB_ROOT"
    [[ -d "$source_lib_dir" ]] || die "Ghostty lib output missing at $source_lib_dir"
    shopt -s nullglob
    local libraries=("$source_lib_dir"/libghostty-vt.so*)
    shopt -u nullglob
    [[ "${#libraries[@]}" -gt 0 ]] || die "libghostty-vt.so output missing under $source_lib_dir"
    cp -P "${libraries[@]}" "$destination_bin/"
    if [[ -f "$destination_bin/libghostty-vt.so.0.1.0" && ! -e "$destination_bin/libghostty-vt.so.0" ]]; then
        (cd "$destination_bin" && ln -s libghostty-vt.so.0.1.0 libghostty-vt.so.0)
    fi
    if [[ -e "$destination_bin/libghostty-vt.so.0" && ! -e "$destination_bin/libghostty-vt.so" ]]; then
        (cd "$destination_bin" && ln -s libghostty-vt.so.0 libghostty-vt.so)
    fi
}

copy_swift_runtime_libraries() {
    local spacesd_bin="$1"
    local destination_lib="$2"
    mkdir -p "$destination_lib"
    while IFS= read -r dependency_path; do
        local basename
        basename="$(basename "$dependency_path")"
        case "$dependency_path:$basename" in
            *"/swift/"*:lib*.so*|*:libswift*.so*|*:libFoundation*.so*|*:libdispatch.so*|*:libBlocksRuntime.so*)
                cp -L "$dependency_path" "$destination_lib/"
                ;;
        esac
    done < <(ldd "$spacesd_bin" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i }' | LC_ALL=C sort -u)
}

write_binary_wrapper() {
    local destination="$1"
    local binary_name="$2"
    cat > "$destination" <<EOF
#!/usr/bin/env bash
set -euo pipefail

source_path="\${BASH_SOURCE[0]:-\$0}"
while [ -L "\$source_path" ]; do
    source_dir="\$(cd -P "\$(dirname "\$source_path")" && pwd)"
    target_path="\$(readlink "\$source_path")"
    case "\$target_path" in
        /*) source_path="\$target_path" ;;
        *) source_path="\$source_dir/\$target_path" ;;
    esac
done

bin_dir="\$(cd -P "\$(dirname "\$source_path")" && pwd)"
artifact_root="\$(cd -P "\$bin_dir/.." && pwd)"
export LD_LIBRARY_PATH="\$artifact_root/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\$artifact_root/bin/$binary_name" "\$@"
EOF
    chmod +x "$destination"
}

write_linux_install_script() {
    local destination="$1"
    cat > "$destination" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source_path="${BASH_SOURCE[0]:-$0}"
while [ -L "$source_path" ]; do
    source_dir="$(cd -P "$(dirname "$source_path")" && pwd)"
    target_path="$(readlink "$source_path")"
    case "$target_path" in
        /*) source_path="$target_path" ;;
        *) source_path="$source_dir/$target_path" ;;
    esac
done

artifact_root="$(cd -P "$(dirname "$source_path")" && pwd)"
manifest_path="$artifact_root/manifest.json"
version="${SPACESD_VERSION:-}"
if [[ -z "$version" ]]; then
    version="$(awk -F'"' '/"app_version":/ { print $4; exit }' "$manifest_path")"
fi
if [[ -z "$version" ]]; then
    echo "Could not determine spacesd artifact version." >&2
    exit 1
fi

install_root="$HOME/.spaces/daemon"
release_parent="$install_root/releases"
release_dir="$release_parent/$version"
release_staging_dir="$release_parent/.install-$version-$$"
previous_release_dir="$release_parent/.previous-$version-$$"
bin_root="$HOME/.spaces/bin"
service_dir="$HOME/.config/systemd/user"
service_path="$service_dir/spacesd.service"
device_api_host="${SPACES_DEVICE_API_HOST:-0.0.0.0}"
device_api_port="${SPACES_DEVICE_API_PORT:-47847}"

cleanup_install_staging() {
    rm -rf "$release_staging_dir"
    if [ -d "$previous_release_dir" ] && [ ! -e "$release_dir" ]; then
        mv "$previous_release_dir" "$release_dir"
    fi
}
trap cleanup_install_staging EXIT

ensure_user_linger() {
    local login_user linger_state error_log
    login_user="$(id -un)"
    error_log="${TMPDIR:-/tmp}/spaces-enable-linger.$$"
    if ! command -v loginctl >/dev/null 2>&1; then
        echo "Spaces needs this Linux account to keep background services running after SSH disconnects, but this system is missing the required service manager." >&2
        exit 1
    fi
    linger_state="$(loginctl show-user "$login_user" -p Linger --value 2>/dev/null || true)"
    if [[ "$linger_state" != "yes" ]]; then
        if ! loginctl enable-linger "$login_user" >"$error_log" 2>&1; then
            echo "Spaces needs this Linux account to keep background services running after SSH disconnects." >&2
            echo "On the Linux device, run: sudo loginctl enable-linger $login_user" >&2
            cat "$error_log" >&2
            rm -f "$error_log"
            exit 1
        fi
    fi
    rm -f "$error_log"
    linger_state="$(loginctl show-user "$login_user" -p Linger --value 2>/dev/null || true)"
    if [[ "$linger_state" != "yes" ]]; then
        echo "Spaces could not confirm that Linux background services stay available after SSH disconnects." >&2
        echo "On the Linux device, run: sudo loginctl enable-linger $login_user, then retry." >&2
        exit 1
    fi
}

mkdir -p "$release_parent" "$bin_root" "$HOME/.spaces/runtime" "$HOME/.spaces/workspaces" "$service_dir"
rm -rf "$release_staging_dir" "$previous_release_dir"
mkdir -p "$release_staging_dir"
cp -a "$artifact_root/." "$release_staging_dir/"
if [ -e "$release_dir" ] || [ -L "$release_dir" ]; then
    mv "$release_dir" "$previous_release_dir"
fi
mv "$release_staging_dir" "$release_dir"
rm -rf "$previous_release_dir"
trap - EXIT

ln -sfn "$release_dir" "$install_root/current"
ln -sfn "$release_dir/bin/spacesd" "$bin_root/spacesd"
ln -sfn "$release_dir/bin/spaces" "$bin_root/spaces"

cat > "$service_path" <<SERVICE
[Unit]
Description=Spaces daemon

[Service]
Type=simple
ExecStart=%h/.spaces/bin/spacesd
Restart=always
RestartSec=2
WorkingDirectory=%h
Environment=SPACES_DB_PATH=%h/.spaces/spaces.db
Environment=SPACES_RUNTIME_DIR=%h/.spaces/runtime
Environment=SPACES_DEVICE_API_HOST=$device_api_host
Environment=SPACES_DEVICE_API_PORT=$device_api_port

[Install]
WantedBy=default.target
SERVICE

ensure_user_linger
systemctl --user daemon-reload
systemctl --user enable spacesd.service
systemctl --user reset-failed spacesd.service >/dev/null 2>&1 || true
systemctl --user restart spacesd.service

printf 'release_dir=%s\n' "$release_dir"
printf 'current=%s\n' "$install_root/current"
printf 'spacesd=%s\n' "$bin_root/spacesd"
printf 'spaces=%s\n' "$bin_root/spaces"
printf 'service=%s\n' "$service_path"
EOF
    chmod +x "$destination"
}

write_manifest() {
    local staging_root="$1"
    local ghostty_sha="$2"
    local archive_name="$3"
    python3 - "$staging_root/manifest.json" \
        "$ARTIFACT_ID" \
        "$BUILD_CONFIGURATION" \
        "$ghostty_sha" \
        "$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)" \
        "$(swift --version | head -n 1)" \
        "$GHOSTTY_BUILD_OPTIMIZE" \
        "$archive_name" \
        "$ARTIFACT_VERSION" <<'PY'
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
artifact_id, configuration, ghostty_sha, git_sha, swift_version, ghostty_optimize, archive_name, app_version = sys.argv[2:10]
manifest = {
    "schema_version": 1,
    "artifact_id": artifact_id,
    "app_version": app_version,
    "platform": "ubuntu-24.04",
    "architecture": artifact_id.rsplit("-", 1)[-1],
    "configuration": configuration,
    "ghostty_sha": ghostty_sha,
    "git_sha": git_sha,
    "swift_version": swift_version,
    "ghostty_build_optimize": ghostty_optimize,
    "archive_name": archive_name,
    "install_hint": "Extract the archive and run ./install.sh as the target user. The Linux account must be allowed to keep background services running after SSH disconnects.",
    "install_root": "~/.spaces/daemon/releases/<app_version>/",
    "current_symlink": "~/.spaces/daemon/current",
    "bin_symlinks": ["~/.spaces/bin/spacesd", "~/.spaces/bin/spaces"],
    "systemd_user_service": "~/.config/systemd/user/spacesd.service",
    "state": {
        "database": "~/.spaces/spaces.db",
        "runtime": "~/.spaces/runtime/",
        "workspaces": "~/.spaces/workspaces/"
    },
    "install_script": "install.sh",
    "cli": "bin/spaces",
    "cli_binary": "bin/spaces-bin",
    "executable": "bin/spacesd",
    "binary": "bin/spacesd-bin",
    "runtime_libraries": "lib/",
    "vt_library": "bin/libghostty-vt.so",
}
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

package_artifact() {
    local product_dir
    product_dir="$(swift_product_dir)"
    local spacesd_bin="$product_dir/spacesd"
    local spaces_bin="$product_dir/spaces"
    [[ -x "$spacesd_bin" ]] || die "spacesd binary missing at $spacesd_bin"
    [[ -x "$spaces_bin" ]] || die "spaces binary missing at $spaces_bin"

    local ghostty_sha
    ghostty_sha="$(resolve_ghostty_sha)"
    local archive_name="$ARTIFACT_ID.tar.gz"
    local staging_parent="$OUTPUT_DIR/.staging"
    local staging_root="$staging_parent/$ARTIFACT_ID"
    rm -rf "$staging_root"
    mkdir -p "$staging_root/bin" "$staging_root/lib"

    cp "$spacesd_bin" "$staging_root/bin/spacesd-bin"
    cp "$spaces_bin" "$staging_root/bin/spaces-bin"
    chmod +x "$staging_root/bin/spacesd-bin"
    chmod +x "$staging_root/bin/spaces-bin"
    write_binary_wrapper "$staging_root/bin/spacesd" "spacesd-bin"
    write_binary_wrapper "$staging_root/bin/spaces" "spaces-bin"
    write_linux_install_script "$staging_root/install.sh"
    copy_swift_runtime_libraries "$spacesd_bin" "$staging_root/lib"
    copy_swift_runtime_libraries "$spaces_bin" "$staging_root/lib"
    copy_ghostty_vt_libraries "$staging_root/bin"
    write_manifest "$staging_root" "$ghostty_sha" "$archive_name"
    (
        cd "$staging_root"
        find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort | sed 's#^\./##' | xargs sha256sum > SHA256SUMS
    )

    mkdir -p "$OUTPUT_DIR"
    rm -f "$OUTPUT_DIR/$archive_name"
    (
        cd "$staging_parent"
        tar -czf "$OUTPUT_DIR/$archive_name" "$ARTIFACT_ID"
    )
    (cd "$OUTPUT_DIR" && sha256sum "$archive_name" > "$archive_name.sha256")
    echo "==> Wrote $OUTPUT_DIR/$archive_name"
}

smoke_artifact() {
    local archive_path="$OUTPUT_DIR/$ARTIFACT_ID.tar.gz"
    [[ -f "$archive_path" ]] || die "artifact archive missing at $archive_path"
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
        mkdir -p "$smoke_root/profile/runtime" "$smoke_root/work"
        env SPACES_DB_PATH="$smoke_root/profile/spaces.db" SPACES_RUNTIME_DIR="$smoke_root/profile/runtime" \
            bin/spacesd >"$smoke_root/spacesd.log" 2>&1 </dev/null &
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
    terminal_root = os.path.abspath(os.path.join(runtime, "terminal"))
    value = 5381
    for byte in terminal_root.encode("utf-8"):
        value = (((value << 5) + value) + byte) & 0xFFFFFFFFFFFFFFFF
    return f"/tmp/spaces-terminal-sockets/service-{value:016x}.sock"

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
    "command": "create",
    "launchConfiguration": {
        "sessionID": "linux-artifact-smoke",
        "backend": "ghostty-embedded",
        "lifetimePolicy": "persistent",
        "title": "artifact smoke",
        "workingDirectory": work,
        "shell": "/bin/bash",
        "command": "echo artifact-smoke; sleep 20",
        "createdAt": "2026-06-11T00:00:00.000Z",
        "workspaceID": "artifact-workspace",
        "kind": "process",
    },
})
if not response.get("ok"):
    raise SystemExit(response)

created_at = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
response = request({
    "command": "agentSignal",
    "sessionID": "linux-artifact-smoke",
    "agentSignal": {
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

terminal_root = os.path.abspath(os.path.join(runtime, "terminal"))
value = 5381
for byte in terminal_root.encode("utf-8"):
    value = (((value << 5) + value) + byte) & 0xFFFFFFFFFFFFFFFF
path = f"/tmp/spaces-terminal-sockets/service-{value:016x}.sock"

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(10)
with sock:
    sock.connect(path)
    sock.sendall(json.dumps({"command": "state", "sessionID": "linux-artifact-smoke"}).encode("utf-8"))
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
    )
    rm -rf "$smoke_root"
}

require_linux_supported_arch
require_command git
require_command python3
require_command sha256sum

if [[ "$BUILD_GHOSTTY_VT" -eq 1 ]]; then
    build_ghostty_vt
fi
stage_ghostty_vt_development_artifacts
build_spaces_products
package_artifact
if [[ "$SMOKE" -eq 1 ]]; then
    smoke_artifact
fi
