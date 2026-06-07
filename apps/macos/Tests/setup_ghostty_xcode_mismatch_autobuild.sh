#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SETUP_SCRIPT="$APP_ROOT/scripts/setup_ghostty.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/spaces-ghostty-xcode-mismatch.XXXXXX")"
cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX

fail() {
    echo "setup_ghostty Xcode mismatch auto-build test failed: $*" >&2
    if [[ -f "$TMP_ROOT/download-only.out" ]]; then
        echo "--- download-only output ---" >&2
        cat "$TMP_ROOT/download-only.out" >&2
    fi
    if [[ -f "$TMP_ROOT/default.out" ]]; then
        echo "--- default output ---" >&2
        cat "$TMP_ROOT/default.out" >&2
    fi
    if [[ -f "$TMP_ROOT/default-dirty.out" ]]; then
        echo "--- default dirty output ---" >&2
        cat "$TMP_ROOT/default-dirty.out" >&2
    fi
    exit 1
}

TEMP_REPO="$TMP_ROOT/repo"
TEMP_APP_ROOT="$TEMP_REPO/apps/macos"
TEMP_GHOSTTY_ROOT="$TEMP_APP_ROOT/vendor/ghostty"
STUB_BIN="$TMP_ROOT/bin"
RELEASE_DIR="$TMP_ROOT/release"
BUILD_LOG="$TMP_ROOT/zig-build.log"
ZIG_CACHE_DIR="$TMP_ROOT/zig-cache"

mkdir -p "$TEMP_APP_ROOT/scripts" "$TEMP_GHOSTTY_ROOT" "$STUB_BIN" "$RELEASE_DIR" "$ZIG_CACHE_DIR"
cp "$SOURCE_SETUP_SCRIPT" "$TEMP_APP_ROOT/scripts/setup_ghostty.sh"
chmod +x "$TEMP_APP_ROOT/scripts/setup_ghostty.sh"

git -C "$TEMP_GHOSTTY_ROOT" init -q
git -C "$TEMP_GHOSTTY_ROOT" config user.email "spaces-test@example.com"
git -C "$TEMP_GHOSTTY_ROOT" config user.name "Spaces Test"
git -C "$TEMP_GHOSTTY_ROOT" config commit.gpgsign false
cat > "$TEMP_GHOSTTY_ROOT/build.zig.zon" <<'EOF'
.{
    .version = "1.0.0",
}
EOF
git -C "$TEMP_GHOSTTY_ROOT" add build.zig.zon
git -C "$TEMP_GHOSTTY_ROOT" -c commit.gpgsign=false commit -q -m "Create Ghostty fixture"
GHOSTTY_SHA="$(git -C "$TEMP_GHOSTTY_ROOT" rev-parse HEAD)"

cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
set -euo pipefail

download_dir=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --dir)
            download_dir="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

[[ -n "$download_dir" ]] || {
    echo "missing --dir" >&2
    exit 2
}

mkdir -p "$download_dir"
cp "$SPACES_TEST_RELEASE_DIR"/* "$download_dir"/
EOF

cat > "$STUB_BIN/xcodebuild" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "-version" ]]; then
    cat <<'VERSION'
Xcode 17.0
Build version 17C52
VERSION
    exit 0
fi

echo "unexpected xcodebuild invocation: $*" >&2
exit 2
EOF

cat > "$STUB_BIN/xcrun" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "swift" && "${2:-}" == "--version" ]]; then
    echo "Swift test version"
    exit 0
fi

echo "unexpected xcrun invocation: $*" >&2
exit 2
EOF

cat > "$STUB_BIN/zig" <<'EOF'
#!/bin/bash
set -euo pipefail

echo "$PWD $*" >> "$SPACES_TEST_BUILD_LOG"

case "${1:-}" in
    env)
        printf '{"global_cache_dir":"%s"}\n' "$SPACES_TEST_ZIG_CACHE_DIR"
        ;;
    build)
        mkdir -p \
            macos/GhosttyKit.xcframework/macos-arm64_x86_64 \
            zig-out/share/ghostty/shell-integration \
            zig-out/share/terminfo \
            zig-out/include/ghostty \
            zig-out/lib
        : > zig-out/include/ghostty/vt.h
        : > zig-out/lib/libghostty-vt.a
        ;;
    *)
        echo "unexpected zig invocation: $*" >&2
        exit 2
        ;;
esac
EOF

chmod +x "$STUB_BIN/gh" "$STUB_BIN/xcodebuild" "$STUB_BIN/xcrun" "$STUB_BIN/zig"

case "$(uname -m)" in
    arm64)
        ZIG_ARCHIVE_NAME="zig-aarch64-macos-0.15.2"
        ;;
    x86_64)
        ZIG_ARCHIVE_NAME="zig-x86_64-macos-0.15.2"
        ;;
    *)
        fail "unsupported test architecture: $(uname -m)"
        ;;
esac

FAKE_ZIG_BIN="$TEMP_APP_ROOT/.local/ghosttyvt/toolchain/$ZIG_ARCHIVE_NAME/zig"
mkdir -p "$(dirname "$FAKE_ZIG_BIN")"
cp "$STUB_BIN/zig" "$FAKE_ZIG_BIN"
chmod +x "$FAKE_ZIG_BIN"

RELEASE_BUILD_ROOT="$TMP_ROOT/release-build"
mkdir -p \
    "$RELEASE_BUILD_ROOT/kit/GhosttyKit.xcframework" \
    "$RELEASE_BUILD_ROOT/resources/ghostty/shell-integration" \
    "$RELEASE_BUILD_ROOT/resources/terminfo" \
    "$RELEASE_BUILD_ROOT/vt/include/ghostty" \
    "$RELEASE_BUILD_ROOT/vt/lib"
: > "$RELEASE_BUILD_ROOT/vt/include/ghostty/vt.h"
: > "$RELEASE_BUILD_ROOT/vt/lib/libghostty-vt.a"

tar -C "$RELEASE_BUILD_ROOT/kit" -czf "$RELEASE_DIR/GhosttyKit.xcframework.tar.gz" "GhosttyKit.xcframework"
tar -C "$RELEASE_BUILD_ROOT/resources" -czf "$RELEASE_DIR/GhosttyKit-resources.tar.gz" "ghostty" "terminfo"
tar -C "$RELEASE_BUILD_ROOT/vt" -czf "$RELEASE_DIR/libghostty-vt.tar.gz" "include" "lib"

python3 - "$RELEASE_DIR" "$GHOSTTY_SHA" <<'PY'
import hashlib
import json
import pathlib
import sys

release_dir = pathlib.Path(sys.argv[1])
ghostty_sha = sys.argv[2]
assets = [
    "GhosttyKit.xcframework.tar.gz",
    "GhosttyKit-resources.tar.gz",
    "libghostty-vt.tar.gz",
]
checksums = {
    asset: hashlib.sha256((release_dir / asset).read_bytes()).hexdigest()
    for asset in assets
}
manifest = {
    "schema_version": 1,
    "ghostty_sha": ghostty_sha,
    "source_url": "https://example.invalid/ghostty.git",
    "zig_version": "0.15.2",
    "build_script_version": 2,
    "xcode_version": "17.0",
    "xcode_build_version": "17C529",
    "swift_version": "Swift release fixture",
    "host_arch": "test",
    "build_optimize": "ReleaseFast",
    "dirty": False,
    "mode": "build",
    "artifact_checksums": checksums,
}
(release_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

(
    cd "$RELEASE_DIR"
    shasum -a 256 \
        "GhosttyKit.xcframework.tar.gz" \
        "GhosttyKit-resources.tar.gz" \
        "libghostty-vt.tar.gz" \
        "manifest.json" > "SHA256SUMS"
)

SETUP_ENV=(
    "PATH=$STUB_BIN:$PATH"
    "SPACES_GHOSTTY_SETUP_SKIP_API_VERIFY=1"
    "SPACES_TEST_BUILD_LOG=$BUILD_LOG"
    "SPACES_TEST_RELEASE_DIR=$RELEASE_DIR"
    "SPACES_TEST_ZIG_CACHE_DIR=$ZIG_CACHE_DIR"
)

set +e
env "${SETUP_ENV[@]}" "$TEMP_APP_ROOT/scripts/setup_ghostty.sh" --download-only > "$TMP_ROOT/download-only.out" 2>&1
DOWNLOAD_ONLY_STATUS=$?
set -e

if [[ "$DOWNLOAD_ONLY_STATUS" -eq 0 ]]; then
    fail "--download-only succeeded despite Xcode build mismatch"
fi

grep -q "Xcode build version" "$TMP_ROOT/download-only.out" || fail "--download-only did not report the Xcode build mismatch"
if grep -q "unbound variable" "$TMP_ROOT/download-only.out"; then
    fail "--download-only masked the Xcode mismatch with a cleanup error"
fi

if [[ -s "$BUILD_LOG" ]]; then
    fail "--download-only invoked the local build path"
fi

touch "$TEMP_GHOSTTY_ROOT/local-dirty-change"

set +e
env "${SETUP_ENV[@]}" "$TEMP_APP_ROOT/scripts/setup_ghostty.sh" > "$TMP_ROOT/default-dirty.out" 2>&1
DIRTY_DEFAULT_STATUS=$?
set -e

if [[ "$DIRTY_DEFAULT_STATUS" -eq 0 ]]; then
    fail "default setup succeeded with a dirty Ghostty submodule"
fi

grep -q "use --build --allow-dirty" "$TMP_ROOT/default-dirty.out" || fail "default dirty setup did not explain how to run local experiments"
if [[ -s "$BUILD_LOG" ]]; then
    fail "default dirty setup invoked the local build path"
fi

rm "$TEMP_GHOSTTY_ROOT/local-dirty-change"

if ! env "${SETUP_ENV[@]}" "$TEMP_APP_ROOT/scripts/setup_ghostty.sh" > "$TMP_ROOT/default.out" 2>&1; then
    fail "default setup failed"
fi

grep -q "building locally instead" "$TMP_ROOT/default.out" || fail "default setup did not report local build fallback"
BUILD_INVOCATIONS="$(grep -c ' build -D' "$BUILD_LOG" || true)"
if [[ "$BUILD_INVOCATIONS" -lt 2 ]]; then
    fail "default setup did not invoke both Ghostty build commands"
fi

LOCAL_MANIFEST="$TEMP_APP_ROOT/.local/ghostty-artifacts/manifest.json"
[[ -f "$LOCAL_MANIFEST" ]] || fail "local manifest was not written"
[[ -d "$TEMP_APP_ROOT/.local/ghosttykit/GhosttyKit.xcframework" ]] || fail "GhosttyKit artifact was not installed"
[[ -f "$TEMP_APP_ROOT/.local/ghosttyvt/include/ghostty/vt.h" ]] || fail "libghostty-vt header was not installed"

python3 - "$LOCAL_MANIFEST" "$GHOSTTY_SHA" <<'PY'
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
expected_sha = sys.argv[2]
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
assert manifest["ghostty_sha"] == expected_sha, manifest
assert manifest["mode"] == "build", manifest
assert manifest["xcode_build_version"] == "17C52", manifest
assert manifest["dirty"] is False, manifest
PY

echo "setup_ghostty Xcode mismatch auto-build test passed"
