#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
SUBMODULE_PATH="apps/macos/vendor/ghostty"
GHOSTTY_SOURCE_ROOT="$REPO_ROOT/$SUBMODULE_PATH"
GHOSTTYVT_ROOT="$APP_ROOT/.local/ghosttyvt"
GHOSTTYVT_INCLUDE_ROOT="$GHOSTTYVT_ROOT/include"
GHOSTTYVT_LIB_ROOT="$GHOSTTYVT_ROOT/lib"

ZIG_VERSION="0.15.2"
GHOSTTY_BUILD_OPTIMIZE="${SPACES_GHOSTTY_BUILD_OPTIMIZE:-ReleaseFast}"
ARTIFACT_ID="spacesd-ubuntu-24.04-x86_64"
OUTPUT_DIR="$REPO_ROOT/dist/linux"
BUILD_CONFIGURATION="release"
BUILD_GHOSTTY_VT=1
SMOKE=1

usage() {
    cat <<'EOF'
Usage: apps/macos/scripts/build_linux_spacesd_artifact.sh [--output-dir DIR] [--debug] [--skip-ghostty-vt-build] [--skip-smoke]

Builds the Ubuntu 24.04 x86_64 remote spacesd artifact. The archive contains:
  spacesd-ubuntu-24.04-x86_64/bin/spacesd
  spacesd-ubuntu-24.04-x86_64/bin/spacesd-bin
  spacesd-ubuntu-24.04-x86_64/bin/libghostty-vt.so*
  spacesd-ubuntu-24.04-x86_64/lib/libswift*.so and related Swift runtime libraries
  spacesd-ubuntu-24.04-x86_64/manifest.json
  spacesd-ubuntu-24.04-x86_64/SHA256SUMS
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

require_linux_x86_64() {
    [[ "$(uname -s)" == "Linux" ]] || die "Linux spacesd artifacts must be built on Linux"
    [[ "$(uname -m)" == "x86_64" ]] || die "Linux spacesd artifacts must be built on x86_64"
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
    local archive_name="zig-x86_64-linux-$ZIG_VERSION"
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

build_spacesd() {
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

write_spacesd_wrapper() {
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

bin_dir="$(cd -P "$(dirname "$source_path")" && pwd)"
artifact_root="$(cd -P "$bin_dir/.." && pwd)"
export LD_LIBRARY_PATH="$artifact_root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$artifact_root/bin/spacesd-bin" "$@"
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
        "$archive_name" <<'PY'
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
artifact_id, configuration, ghostty_sha, git_sha, swift_version, ghostty_optimize, archive_name = sys.argv[2:9]
manifest = {
    "schema_version": 1,
    "artifact_id": artifact_id,
    "platform": "ubuntu-24.04",
    "architecture": "x86_64",
    "configuration": configuration,
    "ghostty_sha": ghostty_sha,
    "git_sha": git_sha,
    "swift_version": swift_version,
    "ghostty_build_optimize": ghostty_optimize,
    "archive_name": archive_name,
    "install_hint": "Extract the archive and put its bin directory on the remote SSH PATH.",
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
    [[ -x "$spacesd_bin" ]] || die "spacesd binary missing at $spacesd_bin"

    local ghostty_sha
    ghostty_sha="$(resolve_ghostty_sha)"
    local archive_name="$ARTIFACT_ID.tar.gz"
    local staging_parent="$OUTPUT_DIR/.staging"
    local staging_root="$staging_parent/$ARTIFACT_ID"
    rm -rf "$staging_root"
    mkdir -p "$staging_root/bin" "$staging_root/lib"

    cp "$spacesd_bin" "$staging_root/bin/spacesd-bin"
    chmod +x "$staging_root/bin/spacesd-bin"
    write_spacesd_wrapper "$staging_root/bin/spacesd"
    copy_swift_runtime_libraries "$spacesd_bin" "$staging_root/lib"
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
        test -x bin/spacesd
        test -x bin/spacesd-bin
        ldd bin/spacesd-bin >/dev/null
        timeout 20s env SPACES_DB_PATH="$smoke_root/profile/spaces.db" SPACESD_PRINT_CERTIFICATE_FINGERPRINT=1 bin/spacesd | grep -q '^SHA256:'
    )
    rm -rf "$smoke_root"
}

require_linux_x86_64
require_command git
require_command python3
require_command sha256sum

if [[ "$BUILD_GHOSTTY_VT" -eq 1 ]]; then
    build_ghostty_vt
fi
stage_ghostty_vt_development_artifacts
build_spacesd
package_artifact
if [[ "$SMOKE" -eq 1 ]]; then
    smoke_artifact
fi
