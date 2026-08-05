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
    if [[ -f "$TMP_ROOT/default-metal.out" ]]; then
        echo "--- default metal output ---" >&2
        cat "$TMP_ROOT/default-metal.out" >&2
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

if [[ "${1:-}" == "-sdk" && "${3:-}" == "metal" ]]; then
    if [[ -n "${SPACES_TEST_METAL_MISSING:-}" ]]; then
        echo "error: error: cannot execute tool 'metal' due to missing Metal Toolchain; use: xcodebuild -downloadComponent MetalToolchain" >&2
        exit 1
    fi
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
        cp "$SPACES_TEST_FAKE_VT_LIB" "zig-out/lib/$SPACES_TEST_FAKE_VT_LIB_NAME"
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
        ZIG_ARCHIVE_NAME="zig-aarch64-macos-0.16.0"
        ;;
    x86_64)
        ZIG_ARCHIVE_NAME="zig-x86_64-macos-0.16.0"
        ;;
    *)
        fail "unsupported test architecture: $(uname -m)"
        ;;
esac

case "$(uname -s)" in
    Darwin)
        FAKE_VT_LIB_NAME="libghostty-vt.dylib"
        FAKE_VT_LIB="$TMP_ROOT/$FAKE_VT_LIB_NAME"
        printf 'void spaces_fake_ghostty_vt(void) {}\n' > "$TMP_ROOT/fake-vt.c"
        cc -dynamiclib "$TMP_ROOT/fake-vt.c" -o "$FAKE_VT_LIB"
        ;;
    Linux)
        FAKE_VT_LIB_NAME="libghostty-vt.so"
        FAKE_VT_LIB="$TMP_ROOT/$FAKE_VT_LIB_NAME"
        printf 'void spaces_fake_ghostty_vt(void) {}\n' > "$TMP_ROOT/fake-vt.c"
        cc -shared -fPIC "$TMP_ROOT/fake-vt.c" -o "$FAKE_VT_LIB"
        ;;
    *)
        fail "unsupported test OS: $(uname -s)"
        ;;
esac

FAKE_ZIG_BIN="$TEMP_APP_ROOT/.local/ghosttyvt/toolchain/$ZIG_ARCHIVE_NAME/zig"
mkdir -p "$(dirname "$FAKE_ZIG_BIN")"
cp "$STUB_BIN/zig" "$FAKE_ZIG_BIN"
chmod +x "$FAKE_ZIG_BIN"

SETUP_ENV=(
    "PATH=$STUB_BIN:$PATH"
    "SPACES_GHOSTTY_SETUP_SKIP_API_VERIFY=1"
    # The fixture parent tree is not a Git checkout, so the shared cache has to be
    # pointed somewhere explicitly; setup_ghostty.sh otherwise derives it from the
    # primary checkout and refuses to guess. Keeping it under TMP_ROOT also stops
    # this test from writing into the developer's real cache.
    "SPACES_GHOSTTY_CACHE_DIR=$TMP_ROOT/ghostty-cache"
    "SPACES_TEST_BUILD_LOG=$BUILD_LOG"
    "SPACES_TEST_RELEASE_DIR=$RELEASE_DIR"
    "SPACES_TEST_ZIG_CACHE_DIR=$ZIG_CACHE_DIR"
    "SPACES_TEST_FAKE_VT_LIB=$FAKE_VT_LIB"
    "SPACES_TEST_FAKE_VT_LIB_NAME=$FAKE_VT_LIB_NAME"
)

# The release fixture is produced by the script under test (--build --package), so every field a
# consumer validates -- the build script version, the Zig version, the host architecture, and the
# digest of the packaged artifact trees -- is the one this checkout computes. Only the recorded
# Xcode build version is then moved off the stub's value, which is the single mismatch this test is
# about. The packaging build writes to a throwaway cache so the runs below still exercise the
# download rather than a cache restore.
if ! env "${SETUP_ENV[@]}" "SPACES_GHOSTTY_CACHE_DIR=$TMP_ROOT/ghostty-cache-package" \
    "$TEMP_APP_ROOT/scripts/setup_ghostty.sh" --build --package "$RELEASE_DIR" \
    > "$TMP_ROOT/release-package.out" 2>&1; then
    echo "--- release package output ---" >&2
    cat "$TMP_ROOT/release-package.out" >&2
    fail "could not package the release fixture with --build --package"
fi

python3 - "$RELEASE_DIR/manifest.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["xcode_build_version"] = "17C529"
path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

(
    cd "$RELEASE_DIR"
    shasum -a 256 \
        "GhosttyKit.xcframework.tar.gz" \
        "GhosttyKit-resources.tar.gz" \
        "libghostty-vt.tar.gz" \
        "manifest.json" > "SHA256SUMS"
)

# Put the fixture back to the state the runs below start from: nothing installed (the Zig stub
# stays), a clean Ghostty source tree, and an empty build log.
rm -rf \
    "$TEMP_APP_ROOT/.local/ghosttykit" \
    "$TEMP_APP_ROOT/.local/ghostty-artifacts" \
    "$TEMP_APP_ROOT/.local/ghosttyvt/include" \
    "$TEMP_APP_ROOT/.local/ghosttyvt/lib"
git -C "$TEMP_GHOSTTY_ROOT" clean -fdx >/dev/null 2>&1
: > "$BUILD_LOG"

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

set +e
env "${SETUP_ENV[@]}" "SPACES_TEST_METAL_MISSING=1" "$TEMP_APP_ROOT/scripts/setup_ghostty.sh" > "$TMP_ROOT/default-metal.out" 2>&1
METAL_DEFAULT_STATUS=$?
set -e

if [[ "$METAL_DEFAULT_STATUS" -eq 0 ]]; then
    fail "default setup succeeded despite a missing Metal Toolchain"
fi

grep -q "Metal Toolchain" "$TMP_ROOT/default-metal.out" || fail "default metal setup did not report the missing Metal Toolchain"
grep -q "xcodebuild -downloadComponent MetalToolchain" "$TMP_ROOT/default-metal.out" \
    || fail "default metal setup did not include the component install command"
if [[ -s "$BUILD_LOG" ]]; then
    fail "default metal setup invoked the local build path"
fi

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
