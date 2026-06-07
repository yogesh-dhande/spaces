#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
VERIFY_SCRIPT="$SCRIPT_DIR/verify_ghosttykit.sh"

SUBMODULE_PATH="apps/macos/vendor/ghostty"
GHOSTTY_SOURCE_ROOT="$REPO_ROOT/$SUBMODULE_PATH"
DEFAULT_GHOSTTY_REPO="https://github.com/yogesh-dhande/ghostty.git"
ARTIFACT_REPO="${SPACES_GHOSTTY_ARTIFACT_REPO:-${GITHUB_REPOSITORY:-yogesh-dhande/spaces}}"
ARTIFACT_RELEASE_PREFIX="ghostty-artifacts-"
BUILD_SCRIPT_VERSION="2"
MANIFEST_SCHEMA_VERSION="1"
VALIDATION_XCODE_BUILD_MISMATCH=42

LOCAL_ROOT="$APP_ROOT/.local"
ARTIFACT_STATE_ROOT="$LOCAL_ROOT/ghostty-artifacts"
LOCAL_MANIFEST="$ARTIFACT_STATE_ROOT/manifest.json"
LOCAL_SHA256SUMS="$ARTIFACT_STATE_ROOT/SHA256SUMS"

GHOSTTYKIT_ROOT="$LOCAL_ROOT/ghosttykit"
XCFRAMEWORK_ROOT="$GHOSTTYKIT_ROOT/GhosttyKit.xcframework"
RESOURCES_ROOT="$GHOSTTYKIT_ROOT/Resources"

GHOSTTYVT_ROOT="$LOCAL_ROOT/ghosttyvt"
GHOSTTYVT_INCLUDE_ROOT="$GHOSTTYVT_ROOT/include"
GHOSTTYVT_LIB_ROOT="$GHOSTTYVT_ROOT/lib"
TOOLCHAIN_ROOT="$GHOSTTYVT_ROOT/toolchain"

ZIG_VERSION="0.15.2"
GHOSTTY_BUILD_OPTIMIZE="${SPACES_GHOSTTY_BUILD_OPTIMIZE:-ReleaseFast}"

MODE="default"
STRICT=0
ALLOW_DIRTY=0
PACKAGE_DIR=""

usage() {
    cat <<'EOF'
Usage: apps/macos/scripts/setup_ghostty.sh [--download-only | --build] [--strict | --allow-dirty] [--package DIR]

Modes:
  default          Reuse matching local artifacts, otherwise download this repo's ghostty-artifacts-<sha> release.
                   If the download only mismatches the local Xcode build, build from source.
  --download-only Download and install this repo's ghostty-artifacts-<sha> release.
  --build         Build GhosttyKit and libghostty-vt from apps/macos/vendor/ghostty.

Options:
  --strict        Require complete release manifests and reject dirty artifact manifests.
  --allow-dirty   Allow --build to use local dirty Ghostty sources and mark the generated manifest dirty.
  --package DIR   After --build, package installed artifacts for the ghostty-artifacts-<sha> release.
EOF
}

die() {
    echo "$*" >&2
    exit 1
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --download-only)
            MODE="download"
            shift
            ;;
        --build)
            MODE="build"
            shift
            ;;
        --strict)
            STRICT=1
            shift
            ;;
        --allow-dirty)
            ALLOW_DIRTY=1
            shift
            ;;
        --package)
            [[ "$#" -ge 2 ]] || die "--package requires an output directory"
            PACKAGE_DIR="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown setup_ghostty.sh argument: $1"
            ;;
    esac
done

if [[ "$STRICT" -eq 1 && "$ALLOW_DIRTY" -eq 1 ]]; then
    die "--strict and --allow-dirty cannot be used together"
fi

if [[ "$ALLOW_DIRTY" -eq 1 && "$MODE" != "build" ]]; then
    die "--allow-dirty is only valid with --build"
fi

if [[ -n "$PACKAGE_DIR" && "$MODE" != "build" ]]; then
    die "--package is only valid with --build"
fi

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

submodule_is_initialized() {
    git -C "$GHOSTTY_SOURCE_ROOT" rev-parse --git-dir >/dev/null 2>&1
}

resolve_ghostty_sha() {
    if submodule_is_initialized; then
        git -C "$GHOSTTY_SOURCE_ROOT" rev-parse HEAD
        return
    fi

    git -C "$REPO_ROOT" ls-files -s -- "$SUBMODULE_PATH" | awk '$1 == "160000" { print $2; exit }'
}

ensure_ghostty_submodule() {
    if submodule_is_initialized; then
        return
    fi

    echo "==> Initializing Ghostty submodule"
    git -C "$REPO_ROOT" submodule update --init --recursive -- "$SUBMODULE_PATH"
}

ghostty_source_url() {
    if submodule_is_initialized; then
        git -C "$GHOSTTY_SOURCE_ROOT" remote get-url origin 2>/dev/null || echo "$DEFAULT_GHOSTTY_REPO"
        return
    fi

    git -C "$REPO_ROOT" config -f .gitmodules "submodule.$SUBMODULE_PATH.url" 2>/dev/null || echo "$DEFAULT_GHOSTTY_REPO"
}

ghostty_dirty_state() {
    if [[ -n "$(git -C "$GHOSTTY_SOURCE_ROOT" status --porcelain)" ]]; then
        echo "true"
    else
        echo "false"
    fi
}

current_xcode_version() {
    command_exists xcodebuild || return 0
    xcodebuild -version 2>/dev/null | awk 'NR == 1 { print $2; exit }'
}

current_xcode_build_version() {
    command_exists xcodebuild || return 0
    xcodebuild -version 2>/dev/null | awk '/^Build version / { print $3; exit }'
}

current_swift_version() {
    command_exists xcrun || return 0
    xcrun swift --version 2>/dev/null | head -n 1
}

artifact_release_tag() {
    printf "%s%s\n" "$ARTIFACT_RELEASE_PREFIX" "$GHOSTTY_SHA"
}

manifest_matches_current_sha() {
    local manifest_path="$1"
    [[ -f "$manifest_path" ]] || return 1

    python3 - "$manifest_path" \
        "$GHOSTTY_SHA" \
        "$MANIFEST_SCHEMA_VERSION" \
        "$BUILD_SCRIPT_VERSION" \
        "$ZIG_VERSION" \
        "$(current_xcode_build_version)" <<'PY'
import json
import sys

manifest_path, expected_sha, expected_schema, expected_script, expected_zig, expected_xcode_build = sys.argv[1:7]
try:
    with open(manifest_path, "r", encoding="utf-8") as handle:
        manifest = json.load(handle)
except Exception:
    sys.exit(1)

if manifest.get("schema_version") != int(expected_schema):
    sys.exit(1)
if manifest.get("ghostty_sha") != expected_sha:
    sys.exit(1)
if manifest.get("build_script_version") != int(expected_script):
    sys.exit(1)
if manifest.get("zig_version") != expected_zig:
    sys.exit(1)
if expected_xcode_build and manifest.get("xcode_build_version") != expected_xcode_build:
    sys.exit(1)
if manifest.get("dirty") is not False:
    sys.exit(1)
sys.exit(0)
PY
}

installed_artifacts_present() {
    [[ -d "$XCFRAMEWORK_ROOT" ]] || return 1
    [[ -d "$RESOURCES_ROOT/ghostty/shell-integration" ]] || return 1
    [[ -d "$RESOURCES_ROOT/terminfo" ]] || return 1
    [[ -f "$GHOSTTYVT_INCLUDE_ROOT/ghostty/vt.h" ]] || return 1
    [[ -d "$GHOSTTYVT_LIB_ROOT" ]] || return 1
    find "$GHOSTTYVT_LIB_ROOT" -maxdepth 1 \( -name 'libghostty-vt*.dylib' -o -name 'libghostty-vt.a' \) -print -quit | grep -q .
}

normalize_ghosttykit_static_library() {
    local macos_lib_dir="$XCFRAMEWORK_ROOT/macos-arm64_x86_64"

    if [[ -f "$macos_lib_dir/ghostty-internal.a" && ! -f "$macos_lib_dir/libghostty-internal.a" ]]; then
        echo "==> Normalizing macOS Ghostty static library name for SwiftPM"
        cp "$macos_lib_dir/ghostty-internal.a" "$macos_lib_dir/libghostty-internal.a"
    fi
    if [[ -f "$macos_lib_dir/ghostty-internal.a" && -f "$macos_lib_dir/libghostty-internal.a" ]]; then
        rm "$macos_lib_dir/ghostty-internal.a"
    fi
    if [[ -f "$XCFRAMEWORK_ROOT/Info.plist" ]]; then
        for library_index in 0 1 2 3 4 5; do
            platform="$(
                /usr/libexec/PlistBuddy -c "Print :AvailableLibraries:${library_index}:SupportedPlatform" \
                    "$XCFRAMEWORK_ROOT/Info.plist" 2>/dev/null || true
            )"
            if [[ "$platform" == "macos" ]]; then
                /usr/libexec/PlistBuddy -c "Set :AvailableLibraries:${library_index}:BinaryPath libghostty-internal.a" \
                    "$XCFRAMEWORK_ROOT/Info.plist" >/dev/null 2>&1 || true
                /usr/libexec/PlistBuddy -c "Set :AvailableLibraries:${library_index}:LibraryPath libghostty-internal.a" \
                    "$XCFRAMEWORK_ROOT/Info.plist" >/dev/null 2>&1 || true
            fi
        done
    fi
}

verify_ghosttykit_contract() {
    if [[ "${SPACES_GHOSTTY_SETUP_SKIP_API_VERIFY:-0}" == "1" ]]; then
        return
    fi

    if [[ -x "$VERIFY_SCRIPT" ]]; then
        echo "==> Verifying GhosttyKit embedded terminal API contract"
        "$VERIFY_SCRIPT" "$XCFRAMEWORK_ROOT"
    fi
}

reuse_local_artifacts_if_valid() {
    if manifest_matches_current_sha "$LOCAL_MANIFEST" && installed_artifacts_present; then
        echo "==> Reusing local Ghostty artifacts for $GHOSTTY_SHA"
        normalize_ghosttykit_static_library
        verify_ghosttykit_contract
        return 0
    fi

    if [[ -f "$LOCAL_MANIFEST" ]]; then
        echo "==> Local Ghostty artifact manifest does not match current Ghostty setup inputs"
    else
        echo "==> Local Ghostty artifact manifest is missing"
    fi
    return 1
}

patch_libxev_for_ios_simulator() {
    local zig_bin="$1"
    local zon_file="$GHOSTTY_SOURCE_ROOT/build.zig.zon"
    [[ -f "$zon_file" ]] || return 0

    local global_cache_dir
    global_cache_dir="$("$zig_bin" env | awk -F'"' '/global_cache_dir/ { print $2; exit }')"
    [[ -n "$global_cache_dir" ]] || return 0

    local libxev_hash
    libxev_hash="$(
        awk '
            /\.libxev = \{/ { in_dep = 1; next }
            in_dep && /hash = / {
                if (match($0, /"[^"]+"/)) {
                    print substr($0, RSTART + 1, RLENGTH - 2)
                    exit
                }
            }
            in_dep && /\},/ { in_dep = 0 }
        ' "$zon_file"
    )"
    [[ -n "$libxev_hash" ]] || return 0

    local backend_file="$global_cache_dir/p/$libxev_hash/src/backend/kqueue.zig"
    [[ -f "$backend_file" ]] || return 0

    if grep -q 'builtin\.os\.tag != \.macos' "$backend_file"; then
        echo "==> Patching libxev Mach-port kqueue registration for iOS builds"
        perl -0pi -e 's/builtin\.os\.tag != \.macos/!builtin.os.tag.isDarwin()/g' "$backend_file"
    fi
}

zig_archive_name() {
    case "$(uname -m)" in
        arm64)
            echo "zig-aarch64-macos-$ZIG_VERSION"
            ;;
        x86_64)
            echo "zig-x86_64-macos-$ZIG_VERSION"
            ;;
        *)
            die "unsupported macOS architecture for Ghostty setup: $(uname -m)"
            ;;
    esac
}

ensure_zig() {
    local archive_name
    archive_name="$(zig_archive_name)"
    local zig_install_root="$TOOLCHAIN_ROOT/$archive_name"
    local zig_bin="$zig_install_root/zig"

    if [[ ! -x "$zig_bin" ]]; then
        echo "==> Downloading Zig $ZIG_VERSION for Ghostty builds" >&2
        local tmp_dir
        tmp_dir="$(mktemp -d)"
        local archive="$archive_name.tar.xz"
        curl -fL "https://ziglang.org/download/$ZIG_VERSION/$archive" -o "$tmp_dir/$archive"
        mkdir -p "$TOOLCHAIN_ROOT"
        tar -xJf "$tmp_dir/$archive" -C "$TOOLCHAIN_ROOT"
        rm -rf "$tmp_dir"
    else
        echo "==> Zig $ZIG_VERSION already present at $zig_bin" >&2
    fi

    echo "$zig_bin"
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

write_manifest() {
    local manifest_path="$1"
    local dirty="$2"
    local mode="$3"
    local kit_checksum="${4:-}"
    local resources_checksum="${5:-}"
    local vt_checksum="${6:-}"

    mkdir -p "$(dirname "$manifest_path")"
    python3 - "$manifest_path" \
        "$MANIFEST_SCHEMA_VERSION" \
        "$GHOSTTY_SHA" \
        "$(ghostty_source_url)" \
        "$ZIG_VERSION" \
        "$BUILD_SCRIPT_VERSION" \
        "$(current_xcode_version)" \
        "$(current_xcode_build_version)" \
        "$(current_swift_version)" \
        "$(uname -m)" \
        "$GHOSTTY_BUILD_OPTIMIZE" \
        "$dirty" \
        "$mode" \
        "$kit_checksum" \
        "$resources_checksum" \
        "$vt_checksum" <<'PY'
import json
import sys

(
    manifest_path,
    schema_version,
    ghostty_sha,
    source_url,
    zig_version,
    build_script_version,
    xcode_version,
    xcode_build_version,
    swift_version,
    host_arch,
    build_optimize,
    dirty,
    mode,
    kit_checksum,
    resources_checksum,
    vt_checksum,
) = sys.argv[1:17]

artifact_checksums = {}
if kit_checksum:
    artifact_checksums["GhosttyKit.xcframework.tar.gz"] = kit_checksum
if resources_checksum:
    artifact_checksums["GhosttyKit-resources.tar.gz"] = resources_checksum
if vt_checksum:
    artifact_checksums["libghostty-vt.tar.gz"] = vt_checksum

manifest = {
    "schema_version": int(schema_version),
    "ghostty_sha": ghostty_sha,
    "source_url": source_url,
    "zig_version": zig_version,
    "build_script_version": int(build_script_version),
    "xcode_version": xcode_version,
    "xcode_build_version": xcode_build_version,
    "swift_version": swift_version,
    "host_arch": host_arch,
    "build_optimize": build_optimize,
    "dirty": dirty == "true",
    "mode": mode,
    "artifact_checksums": artifact_checksums,
    "install_paths": {
        "ghosttykit_xcframework": "apps/macos/.local/ghosttykit/GhosttyKit.xcframework",
        "ghosttykit_resources": "apps/macos/.local/ghosttykit/Resources",
        "ghosttyvt_include": "apps/macos/.local/ghosttyvt/include",
        "ghosttyvt_lib": "apps/macos/.local/ghosttyvt/lib",
    },
}

with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

install_source_build_outputs() {
    local source_xcframework="$GHOSTTY_SOURCE_ROOT/macos/GhosttyKit.xcframework"
    local source_ghostty_resources="$GHOSTTY_SOURCE_ROOT/zig-out/share/ghostty"
    local source_terminfo_resources="$GHOSTTY_SOURCE_ROOT/zig-out/share/terminfo"
    local source_include="$GHOSTTY_SOURCE_ROOT/zig-out/include"
    local source_lib="$GHOSTTY_SOURCE_ROOT/zig-out/lib"

    [[ -d "$source_xcframework" ]] || die "GhosttyKit.xcframework missing at $source_xcframework"
    [[ -d "$source_ghostty_resources" ]] || die "Ghostty resources missing at $source_ghostty_resources"
    [[ -d "$source_terminfo_resources" ]] || die "Ghostty terminfo resources missing at $source_terminfo_resources"
    [[ -f "$source_include/ghostty/vt.h" ]] || die "libghostty-vt headers missing at $source_include"
    [[ -d "$source_lib" ]] || die "libghostty-vt library directory missing at $source_lib"

    echo "==> Installing Ghostty artifacts into apps/macos/.local"
    rm -rf "$XCFRAMEWORK_ROOT" "$RESOURCES_ROOT" "$GHOSTTYVT_INCLUDE_ROOT" "$GHOSTTYVT_LIB_ROOT"
    mkdir -p "$GHOSTTYKIT_ROOT" "$RESOURCES_ROOT" "$GHOSTTYVT_ROOT"

    cp -R "$source_xcframework" "$XCFRAMEWORK_ROOT"
    cp -R "$source_ghostty_resources" "$RESOURCES_ROOT/ghostty"
    cp -R "$source_terminfo_resources" "$RESOURCES_ROOT/terminfo"
    cp -R "$source_include" "$GHOSTTYVT_INCLUDE_ROOT"
    cp -R "$source_lib" "$GHOSTTYVT_LIB_ROOT"
}

build_from_source() {
    ensure_ghostty_submodule
    GHOSTTY_SHA="$(resolve_ghostty_sha)"

    local dirty
    dirty="$(ghostty_dirty_state)"
    if [[ "$dirty" == "true" && "$ALLOW_DIRTY" -ne 1 ]]; then
        die "Ghostty submodule has local modifications; commit them before building artifacts or use --build --allow-dirty for local experiments"
    fi

    local zig_bin
    zig_bin="$(ensure_zig)"
    local app_version
    app_version="$(ghostty_app_version)"

    echo "==> Building Ghostty artifacts from $GHOSTTY_SOURCE_ROOT ($GHOSTTY_SHA, optimize=$GHOSTTY_BUILD_OPTIMIZE)"
    patch_libxev_for_ios_simulator "$zig_bin"
    (
        cd "$GHOSTTY_SOURCE_ROOT"
        "$zig_bin" build -Doptimize="$GHOSTTY_BUILD_OPTIMIZE" -Demit-xcframework=true -Demit-macos-app=false -Di18n=false -Dversion-string="$app_version"
        "$zig_bin" build -Doptimize="$GHOSTTY_BUILD_OPTIMIZE" -Demit-lib-vt=true -Dversion-string="$app_version"
    )

    install_source_build_outputs
    normalize_ghosttykit_static_library
    write_manifest "$LOCAL_MANIFEST" "$dirty" "build"
    verify_ghosttykit_contract

    if [[ -n "$PACKAGE_DIR" ]]; then
        package_installed_artifacts "$PACKAGE_DIR" "$dirty"
    fi
}

validate_download_manifest() {
    local manifest_path="$1"
    local download_dir="$2"

    python3 - "$manifest_path" \
        "$GHOSTTY_SHA" \
        "$MANIFEST_SCHEMA_VERSION" \
        "$STRICT" \
        "$download_dir" \
        "$BUILD_SCRIPT_VERSION" \
        "$ZIG_VERSION" \
        "$(current_xcode_build_version)" \
        "$VALIDATION_XCODE_BUILD_MISMATCH" <<'PY'
import hashlib
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
expected_sha = sys.argv[2]
expected_schema = int(sys.argv[3])
strict = sys.argv[4] == "1"
download_dir = pathlib.Path(sys.argv[5])
expected_script = int(sys.argv[6])
expected_zig = sys.argv[7]
expected_xcode_build = sys.argv[8]
xcode_build_mismatch_status = int(sys.argv[9])
assets = [
    "GhosttyKit.xcframework.tar.gz",
    "GhosttyKit-resources.tar.gz",
    "libghostty-vt.tar.gz",
]

try:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
except Exception as error:
    print(f"invalid Ghostty artifact manifest: {error}", file=sys.stderr)
    sys.exit(1)

if manifest.get("ghostty_sha") != expected_sha:
    print(
        f"Ghostty artifact manifest SHA {manifest.get('ghostty_sha')} does not match submodule SHA {expected_sha}",
        file=sys.stderr,
    )
    sys.exit(1)

if manifest.get("schema_version") != expected_schema:
    print(
        f"Ghostty artifact manifest schema {manifest.get('schema_version')} does not match expected schema {expected_schema}",
        file=sys.stderr,
    )
    sys.exit(1)

if manifest.get("build_script_version") != expected_script:
    print(
        f"Ghostty artifact manifest build script version {manifest.get('build_script_version')} "
        f"does not match expected version {expected_script}; rebuild or republish the artifacts.",
        file=sys.stderr,
    )
    sys.exit(1)

if manifest.get("zig_version") != expected_zig:
    print(
        f"Ghostty artifact manifest Zig version {manifest.get('zig_version')} does not match expected version {expected_zig}; "
        "rebuild or republish the artifacts.",
        file=sys.stderr,
    )
    sys.exit(1)

xcode_build_mismatch = False
if expected_xcode_build and manifest.get("xcode_build_version") != expected_xcode_build:
    print(
        f"Ghostty artifact manifest Xcode build version {manifest.get('xcode_build_version')} does not match current "
        f"Xcode build version {expected_xcode_build}; rebuild locally with --build or publish artifacts built with the current Xcode.",
        file=sys.stderr,
    )
    xcode_build_mismatch = True

if strict and manifest.get("dirty") is not False:
    print("strict Ghostty artifact setup refuses dirty artifact manifests", file=sys.stderr)
    sys.exit(1)

checksums = manifest.get("artifact_checksums") or {}
for asset in assets:
    path = download_dir / asset
    if not path.is_file():
        print(f"missing Ghostty artifact asset: {asset}", file=sys.stderr)
        sys.exit(1)

    expected_checksum = checksums.get(asset)
    if not expected_checksum:
        if strict:
            print(f"manifest is missing checksum for {asset}", file=sys.stderr)
            sys.exit(1)
        continue

    actual_checksum = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual_checksum != expected_checksum:
        print(
            f"checksum mismatch for {asset}: manifest has {expected_checksum}, downloaded {actual_checksum}",
            file=sys.stderr,
        )
        sys.exit(1)

if xcode_build_mismatch:
    sys.exit(xcode_build_mismatch_status)
PY
}

download_release_artifacts() {
    command_exists gh || die "GitHub CLI 'gh' is required to download Ghostty artifacts"
    local release_tag
    release_tag="$(artifact_release_tag)"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT

    echo "==> Downloading Ghostty artifacts from $ARTIFACT_REPO ($release_tag)"
    if ! gh release download "$release_tag" \
        --repo "$ARTIFACT_REPO" \
        --dir "$tmp_dir" \
        --pattern "GhosttyKit.xcframework.tar.gz" \
        --pattern "GhosttyKit-resources.tar.gz" \
        --pattern "libghostty-vt.tar.gz" \
        --pattern "manifest.json" \
        --pattern "SHA256SUMS"; then
        die "missing Ghostty artifact release $release_tag in $ARTIFACT_REPO; use apps/macos/scripts/ensure_ghostty_artifacts.sh on a trusted workflow or build locally with --build"
    fi

    [[ -f "$tmp_dir/manifest.json" ]] || die "Ghostty artifact release $release_tag is missing manifest.json"
    if [[ -f "$tmp_dir/SHA256SUMS" ]]; then
        (cd "$tmp_dir" && shasum -a 256 -c SHA256SUMS)
    elif [[ "$STRICT" -eq 1 ]]; then
        die "Ghostty artifact release $release_tag is missing SHA256SUMS"
    fi

    local validation_status
    if validate_download_manifest "$tmp_dir/manifest.json" "$tmp_dir"; then
        validation_status=0
    else
        validation_status=$?
    fi

    if [[ "$validation_status" -eq "$VALIDATION_XCODE_BUILD_MISMATCH" && "$MODE" == "default" ]]; then
        rm -rf "$tmp_dir"
        trap - EXIT
        echo "==> Downloaded Ghostty artifacts were built with a different Xcode build; building locally instead"
        build_from_source
        return
    fi

    if [[ "$validation_status" -ne 0 ]]; then
        rm -rf "$tmp_dir"
        trap - EXIT
        return "$validation_status"
    fi

    echo "==> Installing downloaded Ghostty artifacts"
    rm -rf "$XCFRAMEWORK_ROOT" "$RESOURCES_ROOT" "$GHOSTTYVT_INCLUDE_ROOT" "$GHOSTTYVT_LIB_ROOT"
    mkdir -p "$GHOSTTYKIT_ROOT" "$RESOURCES_ROOT" "$GHOSTTYVT_ROOT" "$ARTIFACT_STATE_ROOT"

    tar xzf "$tmp_dir/GhosttyKit.xcframework.tar.gz" -C "$GHOSTTYKIT_ROOT"
    tar xzf "$tmp_dir/GhosttyKit-resources.tar.gz" -C "$RESOURCES_ROOT"
    tar xzf "$tmp_dir/libghostty-vt.tar.gz" -C "$GHOSTTYVT_ROOT"

    cp "$tmp_dir/manifest.json" "$LOCAL_MANIFEST"
    if [[ -f "$tmp_dir/SHA256SUMS" ]]; then
        cp "$tmp_dir/SHA256SUMS" "$LOCAL_SHA256SUMS"
    fi
    rm -rf "$tmp_dir"
    trap - EXIT

    normalize_ghosttykit_static_library
    verify_ghosttykit_contract
}

sha256_file() {
    shasum -a 256 "$1" | awk '{ print $1 }'
}

package_installed_artifacts() {
    local package_dir="$1"
    local dirty="$2"
    installed_artifacts_present || die "cannot package incomplete Ghostty artifact install"

    mkdir -p "$package_dir"
    rm -f \
        "$package_dir/GhosttyKit.xcframework.tar.gz" \
        "$package_dir/GhosttyKit-resources.tar.gz" \
        "$package_dir/libghostty-vt.tar.gz" \
        "$package_dir/manifest.json" \
        "$package_dir/SHA256SUMS"

    echo "==> Packaging Ghostty artifacts into $package_dir"
    tar -C "$GHOSTTYKIT_ROOT" -czf "$package_dir/GhosttyKit.xcframework.tar.gz" "GhosttyKit.xcframework"
    tar -C "$RESOURCES_ROOT" -czf "$package_dir/GhosttyKit-resources.tar.gz" "ghostty" "terminfo"
    tar -C "$GHOSTTYVT_ROOT" -czf "$package_dir/libghostty-vt.tar.gz" "include" "lib"

    local kit_checksum
    local resources_checksum
    local vt_checksum
    kit_checksum="$(sha256_file "$package_dir/GhosttyKit.xcframework.tar.gz")"
    resources_checksum="$(sha256_file "$package_dir/GhosttyKit-resources.tar.gz")"
    vt_checksum="$(sha256_file "$package_dir/libghostty-vt.tar.gz")"
    write_manifest "$package_dir/manifest.json" "$dirty" "build" "$kit_checksum" "$resources_checksum" "$vt_checksum"

    (
        cd "$package_dir"
        shasum -a 256 \
            "GhosttyKit.xcframework.tar.gz" \
            "GhosttyKit-resources.tar.gz" \
            "libghostty-vt.tar.gz" \
            "manifest.json" > "SHA256SUMS"
    )
}

GHOSTTY_SHA="$(resolve_ghostty_sha)"
[[ -n "$GHOSTTY_SHA" ]] || die "unable to resolve Ghostty submodule SHA at $SUBMODULE_PATH"

case "$MODE" in
    default)
        if ! reuse_local_artifacts_if_valid; then
            download_release_artifacts
        fi
        ;;
    download)
        download_release_artifacts
        ;;
    build)
        build_from_source
        ;;
    *)
        die "unsupported Ghostty setup mode: $MODE"
        ;;
esac

echo
echo "Ghostty setup complete."
echo "  ghostty sha: $GHOSTTY_SHA"
echo "  xcframework: $XCFRAMEWORK_ROOT"
echo "  resources:   $RESOURCES_ROOT/ghostty"
echo "  vt include:  $GHOSTTYVT_INCLUDE_ROOT"
echo "  vt lib:      $GHOSTTYVT_LIB_ROOT"
echo
echo "Runtime overrides:"
echo "  export SPACES_GHOSTTYKIT_XCFRAMEWORK=\"$XCFRAMEWORK_ROOT\""
echo "  export SPACES_GHOSTTY_RESOURCES_DIR=\"$RESOURCES_ROOT/ghostty\""
echo "  export SPACES_GHOSTTY_VT_DYLIB_PATH=\"$GHOSTTYVT_LIB_ROOT/libghostty-vt.dylib\""
