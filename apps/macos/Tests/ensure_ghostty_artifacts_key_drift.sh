#!/bin/bash
set -euo pipefail

# Prebuilt Ghostty artifacts are only reusable while the published manifest key -- the setup
# script's BUILD_SCRIPT_VERSION plus the exact Xcode build version -- still matches what consumers
# compute. This test drives ensure_ghostty_artifacts.sh against a stubbed release and proves the
# three states that decide whether a build is skipped:
#
#   1. published key drifted (older BUILD_SCRIPT_VERSION) -> rebuild and republish
#   2. published key matches                              -> download and reuse, no build, no upload
#   3. published key drifted (different Xcode build)      -> rebuild and republish
#
# Everything expensive is stubbed: `gh` reads and writes a directory standing in for the release,
# and `zig` fabricates the build outputs. The manifest fixture derives BUILD_SCRIPT_VERSION and
# ZIG_VERSION from setup_ghostty.sh so a future bump cannot silently turn the "matching" case into
# an accidental mismatch.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SETUP_SCRIPT="$APP_ROOT/scripts/setup_ghostty.sh"
SOURCE_ENSURE_SCRIPT="$APP_ROOT/scripts/ensure_ghostty_artifacts.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/spaces-ghostty-key-drift.XXXXXX")"
cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
unset RUNNER_TEMP

CURRENT_OUT=""
fail() {
    echo "ensure_ghostty_artifacts key drift test failed: $*" >&2
    if [[ -n "$CURRENT_OUT" && -f "$CURRENT_OUT" ]]; then
        echo "--- last ensure output ---" >&2
        cat "$CURRENT_OUT" >&2
    fi
    exit 1
}

TEMP_REPO="$TMP_ROOT/repo"
TEMP_APP_ROOT="$TEMP_REPO/apps/macos"
TEMP_GHOSTTY_ROOT="$TEMP_APP_ROOT/vendor/ghostty"
STUB_BIN="$TMP_ROOT/bin"
RELEASE_STORE="$TMP_ROOT/release-store"
BUILD_LOG="$TMP_ROOT/zig-build.log"
GH_LOG="$TMP_ROOT/gh.log"
ZIG_CACHE_DIR="$TMP_ROOT/zig-cache"
CACHE_DIR="$TMP_ROOT/ghostty-cache"

mkdir -p "$TEMP_APP_ROOT/scripts" "$TEMP_GHOSTTY_ROOT" "$STUB_BIN" "$RELEASE_STORE" "$ZIG_CACHE_DIR"
cp "$SOURCE_SETUP_SCRIPT" "$SOURCE_ENSURE_SCRIPT" "$TEMP_APP_ROOT/scripts/"
chmod +x "$TEMP_APP_ROOT/scripts/setup_ghostty.sh" "$TEMP_APP_ROOT/scripts/ensure_ghostty_artifacts.sh"

script_constant() {
    sed -n "s/^$1=\"\\(.*\\)\"$/\\1/p" "$SOURCE_SETUP_SCRIPT" | head -n 1
}

BUILD_SCRIPT_VERSION="$(script_constant BUILD_SCRIPT_VERSION)"
ZIG_VERSION="$(script_constant ZIG_VERSION)"
MANIFEST_SCHEMA_VERSION="$(script_constant MANIFEST_SCHEMA_VERSION)"
[[ -n "$BUILD_SCRIPT_VERSION" ]] || fail "could not read BUILD_SCRIPT_VERSION from setup_ghostty.sh"
[[ -n "$ZIG_VERSION" ]] || fail "could not read ZIG_VERSION from setup_ghostty.sh"
[[ -n "$MANIFEST_SCHEMA_VERSION" ]] || fail "could not read MANIFEST_SCHEMA_VERSION from setup_ghostty.sh"
STALE_BUILD_SCRIPT_VERSION="$((BUILD_SCRIPT_VERSION - 1))"

# Ghostty fixture: a committed repo whose build outputs are ignored, so repeated stub builds keep
# the submodule clean and --strict never rejects it as dirty.
git -C "$TEMP_GHOSTTY_ROOT" init -q
git -C "$TEMP_GHOSTTY_ROOT" config user.email "spaces-test@example.com"
git -C "$TEMP_GHOSTTY_ROOT" config user.name "Spaces Test"
git -C "$TEMP_GHOSTTY_ROOT" config commit.gpgsign false
cat > "$TEMP_GHOSTTY_ROOT/build.zig.zon" <<'EOF'
.{
    .version = "1.0.0",
}
EOF
cat > "$TEMP_GHOSTTY_ROOT/.gitignore" <<'EOF'
macos/
zig-out/
EOF
git -C "$TEMP_GHOSTTY_ROOT" add build.zig.zon .gitignore
git -C "$TEMP_GHOSTTY_ROOT" -c commit.gpgsign=false commit -q -m "Create Ghostty fixture"
GHOSTTY_SHA="$(git -C "$TEMP_GHOSTTY_ROOT" rev-parse HEAD)"
RELEASE_TAG="ghostty-artifacts-$GHOSTTY_SHA"

# ensure_ghostty_artifacts.sh reads the pinned SHA from the parent repo's gitlink, so the fixture
# needs a real one in the index.
git -C "$TEMP_REPO" init -q
git -C "$TEMP_REPO" config user.email "spaces-test@example.com"
git -C "$TEMP_REPO" config user.name "Spaces Test"
git -C "$TEMP_REPO" update-index --add --cacheinfo "160000,$GHOSTTY_SHA,apps/macos/vendor/ghostty"

cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
set -euo pipefail

printf '%s\n' "$*" >> "$SPACES_TEST_GH_LOG"

command="${1:-}"
subcommand="${2:-}"
shift 2 || true

case "$command $subcommand" in
    "release view")
        if [[ -f "$SPACES_TEST_RELEASE_STORE/manifest.json" ]]; then
            echo "release $SPACES_TEST_RELEASE_TAG"
            exit 0
        fi
        echo "release not found" >&2
        exit 1
        ;;
    "release download")
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
        [[ -n "$download_dir" ]] || { echo "missing --dir" >&2; exit 2; }
        [[ -f "$SPACES_TEST_RELEASE_STORE/manifest.json" ]] || { echo "release not found" >&2; exit 1; }
        mkdir -p "$download_dir"
        cp "$SPACES_TEST_RELEASE_STORE"/* "$download_dir"/
        ;;
    "release create"|"release upload")
        assets=()
        shift || true # the release tag
        while [[ "$#" -gt 0 ]]; do
            case "$1" in
                --repo|--title|--notes)
                    shift 2
                    ;;
                --prerelease|--clobber)
                    shift
                    ;;
                *)
                    assets+=("$1")
                    shift
                    ;;
            esac
        done
        mkdir -p "$SPACES_TEST_RELEASE_STORE"
        for asset in "${assets[@]}"; do
            cp "$asset" "$SPACES_TEST_RELEASE_STORE"/
        done
        ;;
    "release edit")
        ;;
    *)
        echo "unexpected gh invocation: $command $subcommand $*" >&2
        exit 2
        ;;
esac
EOF

cat > "$STUB_BIN/xcodebuild" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "-version" ]]; then
    echo "Xcode 26.3"
    echo "Build version $SPACES_TEST_XCODE_BUILD"
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
        ZIG_ARCHIVE_NAME="zig-aarch64-macos-$ZIG_VERSION"
        ;;
    x86_64)
        ZIG_ARCHIVE_NAME="zig-x86_64-macos-$ZIG_VERSION"
        ;;
    *)
        fail "unsupported test architecture: $(uname -m)"
        ;;
esac

FAKE_VT_LIB_NAME="libghostty-vt.dylib"
FAKE_VT_LIB="$TMP_ROOT/$FAKE_VT_LIB_NAME"
printf 'void spaces_fake_ghostty_vt(void) {}\n' > "$TMP_ROOT/fake-vt.c"
cc -dynamiclib "$TMP_ROOT/fake-vt.c" -o "$FAKE_VT_LIB"

FAKE_ZIG_BIN="$TEMP_APP_ROOT/.local/ghosttyvt/toolchain/$ZIG_ARCHIVE_NAME/zig"
mkdir -p "$(dirname "$FAKE_ZIG_BIN")"
cp "$STUB_BIN/zig" "$FAKE_ZIG_BIN"
chmod +x "$FAKE_ZIG_BIN"

# Seeds the stubbed release with artifacts whose manifest carries the given key. Only the manifest
# key matters here, so the payload tarballs are empty shells with real checksums.
seed_release() {
    local manifest_build_script_version="$1"
    local manifest_xcode_build="$2"
    local manifest_schema_version="$3"
    local build_root="$TMP_ROOT/seed"

    rm -rf "$build_root" "$RELEASE_STORE"
    mkdir -p \
        "$build_root/kit/GhosttyKit.xcframework" \
        "$build_root/resources/ghostty/shell-integration" \
        "$build_root/resources/terminfo" \
        "$build_root/vt/include/ghostty" \
        "$build_root/vt/lib" \
        "$RELEASE_STORE"
    : > "$build_root/vt/include/ghostty/vt.h"
    cp "$FAKE_VT_LIB" "$build_root/vt/lib/$FAKE_VT_LIB_NAME"

    tar -C "$build_root/kit" -czf "$RELEASE_STORE/GhosttyKit.xcframework.tar.gz" "GhosttyKit.xcframework"
    tar -C "$build_root/resources" -czf "$RELEASE_STORE/GhosttyKit-resources.tar.gz" "ghostty" "terminfo"
    tar -C "$build_root/vt" -czf "$RELEASE_STORE/libghostty-vt.tar.gz" "include" "lib"

    # host_arch is the real host architecture, and the schema version comes from the script under
    # test: both are part of the artifact key, so a placeholder would make every seeded release fail
    # on that axis instead of exercising the build-script-version and Xcode drift this test is
    # about. The content digest is a placeholder because a seeded release is always rejected on its
    # key before anything is extracted, which is the only point at which a digest is compared.
    python3 - "$RELEASE_STORE" "$GHOSTTY_SHA" "$manifest_build_script_version" "$ZIG_VERSION" \
        "$manifest_xcode_build" "$(uname -m)" "$manifest_schema_version" <<'PY'
import hashlib
import json
import pathlib
import sys

release_dir = pathlib.Path(sys.argv[1])
ghostty_sha, build_script_version, zig_version, xcode_build, host_arch, schema_version = sys.argv[2:8]
assets = [
    "GhosttyKit.xcframework.tar.gz",
    "GhosttyKit-resources.tar.gz",
    "libghostty-vt.tar.gz",
]
manifest = {
    "schema_version": int(schema_version),
    "ghostty_sha": ghostty_sha,
    "source_url": "https://example.invalid/ghostty.git",
    "zig_version": zig_version,
    "build_script_version": int(build_script_version),
    "xcode_version": "26.3",
    "xcode_build_version": xcode_build,
    "swift_version": "Swift release fixture",
    "host_arch": host_arch,
    "build_optimize": "ReleaseFast",
    "dirty": False,
    "mode": "build",
    "artifact_content_digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    "artifact_checksums": {
        asset: hashlib.sha256((release_dir / asset).read_bytes()).hexdigest()
        for asset in assets
    },
}
(release_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

    (
        cd "$RELEASE_STORE"
        shasum -a 256 \
            "GhosttyKit.xcframework.tar.gz" \
            "GhosttyKit-resources.tar.gz" \
            "libghostty-vt.tar.gz" \
            "manifest.json" > "SHA256SUMS"
    )
}

published_manifest_field() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
        "$RELEASE_STORE/manifest.json" "$1"
}

run_ensure() {
    local label="$1"
    local xcode_build="$2"
    CURRENT_OUT="$TMP_ROOT/$label.out"

    : > "$BUILD_LOG"
    : > "$GH_LOG"
    rm -rf "$TEMP_APP_ROOT/.local/ghostty-artifacts" \
        "$TEMP_APP_ROOT/.local/ghosttykit" \
        "$TEMP_APP_ROOT/.local/ghosttyvt/include" \
        "$TEMP_APP_ROOT/.local/ghosttyvt/lib" \
        "$CACHE_DIR"

    env \
        "PATH=$STUB_BIN:$PATH" \
        "SPACES_GHOSTTY_SETUP_SKIP_API_VERIFY=1" \
        "SPACES_GHOSTTY_ARTIFACT_REPO=spaces-test/fixture" \
        "SPACES_GHOSTTY_CACHE_DIR=$CACHE_DIR" \
        "SPACES_TEST_BUILD_LOG=$BUILD_LOG" \
        "SPACES_TEST_GH_LOG=$GH_LOG" \
        "SPACES_TEST_RELEASE_STORE=$RELEASE_STORE" \
        "SPACES_TEST_RELEASE_TAG=$RELEASE_TAG" \
        "SPACES_TEST_XCODE_BUILD=$xcode_build" \
        "SPACES_TEST_ZIG_CACHE_DIR=$ZIG_CACHE_DIR" \
        "SPACES_TEST_FAKE_VT_LIB=$FAKE_VT_LIB" \
        "SPACES_TEST_FAKE_VT_LIB_NAME=$FAKE_VT_LIB_NAME" \
        "$TEMP_APP_ROOT/scripts/ensure_ghostty_artifacts.sh" --publish-missing \
        > "$CURRENT_OUT" 2>&1 \
        || fail "$label: ensure_ghostty_artifacts.sh --publish-missing exited nonzero"
}

built_locally() {
    grep -q ' build -D' "$BUILD_LOG"
}

uploaded_assets() {
    grep -qE '^release (upload|create) ' "$GH_LOG"
}

# 1. A published release built by an older setup script must be refreshed, not accepted.
seed_release "$STALE_BUILD_SCRIPT_VERSION" "17C529" "$MANIFEST_SCHEMA_VERSION"
run_ensure "stale-build-script" "17C529"
grep -q "is invalid or incomplete; rebuilding for repair" "$CURRENT_OUT" \
    || fail "stale build_script_version was not classified as a release needing repair"
built_locally || fail "stale build_script_version did not trigger a rebuild"
uploaded_assets || fail "stale build_script_version did not republish the release"
[[ "$(published_manifest_field build_script_version)" == "$BUILD_SCRIPT_VERSION" ]] \
    || fail "republished manifest did not carry the current build script version"
[[ "$(published_manifest_field xcode_build_version)" == "17C529" ]] \
    || fail "republished manifest did not carry the building toolchain's Xcode build version"

# 2. The release republished above now matches the current key, so the next run must reuse it.
run_ensure "matching-key" "17C529"
grep -q "Installing downloaded Ghostty artifacts" "$CURRENT_OUT" \
    || fail "a release matching the current key was not installed from the download"
if built_locally; then
    fail "a release matching the current key still triggered a rebuild"
fi
if uploaded_assets; then
    fail "a release matching the current key was republished anyway"
fi

# 3. Moving the toolchain drifts the key the other way and must also refresh the release.
run_ensure "stale-xcode-build" "17D100"
grep -q "is invalid or incomplete; rebuilding for repair" "$CURRENT_OUT" \
    || fail "stale xcode_build_version was not classified as a release needing repair"
built_locally || fail "stale xcode_build_version did not trigger a rebuild"
uploaded_assets || fail "stale xcode_build_version did not republish the release"
[[ "$(published_manifest_field xcode_build_version)" == "17D100" ]] \
    || fail "republished manifest did not carry the new Xcode build version"

# 4. A release published under an older manifest schema is stranded the same way. The schema moves
#    when the manifest itself changes meaning (a field consumers now require), so the release has to
#    be rebuilt and republished rather than accepted or reported as complete.
seed_release "$BUILD_SCRIPT_VERSION" "17D100" "$((MANIFEST_SCHEMA_VERSION - 1))"
run_ensure "stale-schema" "17D100"
grep -q "is invalid or incomplete; rebuilding for repair" "$CURRENT_OUT" \
    || fail "an older manifest schema was not classified as a release needing repair"
built_locally || fail "an older manifest schema did not trigger a rebuild"
uploaded_assets || fail "an older manifest schema did not republish the release"
[[ "$(published_manifest_field schema_version)" == "$MANIFEST_SCHEMA_VERSION" ]] \
    || fail "republished manifest did not carry the current manifest schema"

# The republished release is usable: the next run downloads and installs it, which only succeeds
# when the artifacts it ships still hash to the digest its manifest records.
run_ensure "republished-schema" "17D100"
grep -q "Installing downloaded Ghostty artifacts" "$CURRENT_OUT" \
    || fail "the republished release was not installed from the download"
if built_locally; then
    fail "the republished release still triggered a rebuild"
fi

echo "ensure_ghostty_artifacts key drift test passed"
