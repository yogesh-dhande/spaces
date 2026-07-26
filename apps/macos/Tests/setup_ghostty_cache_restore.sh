#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SETUP_SCRIPT="$APP_ROOT/scripts/setup_ghostty.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/spaces-ghostty-cache-restore.XXXXXX")"
cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX

fail() {
    echo "setup_ghostty cache restore test failed: $*" >&2
    for log in seed.out empty-submodule.out restore.out dirty-build.out foreign-arch.out foreign-arch-reuse.out \
        coexist-current-seed.out coexist-bumped-seed.out coexist-current-restore.out coexist-bumped-restore.out; do
        if [[ -f "$TMP_ROOT/$log" ]]; then
            echo "--- $log ---" >&2
            cat "$TMP_ROOT/$log" >&2
        fi
    done
    exit 1
}

TEMP_REPO="$TMP_ROOT/repo"
TEMP_APP_ROOT="$TEMP_REPO/apps/macos"
TEMP_GHOSTTY_ROOT="$TEMP_APP_ROOT/vendor/ghostty"
STUB_BIN="$TMP_ROOT/bin"
RELEASE_DIR="$TMP_ROOT/release"
CACHE_DIR="$TMP_ROOT/cache"
BUILD_LOG="$TMP_ROOT/zig-build.log"
ZIG_CACHE_DIR="$TMP_ROOT/zig-cache"
GH_LOG="$TMP_ROOT/gh-invocations.log"

mkdir -p "$TEMP_APP_ROOT/scripts" "$TEMP_GHOSTTY_ROOT" "$STUB_BIN" "$RELEASE_DIR" "$CACHE_DIR" "$ZIG_CACHE_DIR"
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

# gh stub records each invocation and copies the release fixture into the
# requested download dir. When SPACES_TEST_GH_FAIL is set it fails instead, so
# the restore run proves it never needed the network.
cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
set -euo pipefail

echo "gh $*" >> "$SPACES_TEST_GH_LOG"
if [[ -n "${SPACES_TEST_GH_FAIL:-}" ]]; then
    echo "gh stub forced failure" >&2
    exit 1
fi

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

ARCH="$(uname -m)"
case "$ARCH" in
    arm64)
        ZIG_ARCHIVE_NAME="zig-aarch64-macos-0.16.0"
        ;;
    x86_64)
        ZIG_ARCHIVE_NAME="zig-x86_64-macos-0.16.0"
        ;;
    *)
        fail "unsupported test architecture: $ARCH"
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

place_fake_zig() {
    local zig_bin="$TEMP_APP_ROOT/.local/ghosttyvt/toolchain/$ZIG_ARCHIVE_NAME/zig"
    mkdir -p "$(dirname "$zig_bin")"
    cp "$STUB_BIN/zig" "$zig_bin"
    chmod +x "$zig_bin"
}

# Build a release fixture whose Xcode build version matches the stub so the
# download path installs cleanly (no Xcode-mismatch auto-build).
RELEASE_BUILD_ROOT="$TMP_ROOT/release-build"
mkdir -p \
    "$RELEASE_BUILD_ROOT/kit/GhosttyKit.xcframework" \
    "$RELEASE_BUILD_ROOT/resources/ghostty/shell-integration" \
    "$RELEASE_BUILD_ROOT/resources/terminfo" \
    "$RELEASE_BUILD_ROOT/vt/include/ghostty" \
    "$RELEASE_BUILD_ROOT/vt/lib"
: > "$RELEASE_BUILD_ROOT/vt/include/ghostty/vt.h"
: > "$RELEASE_BUILD_ROOT/vt/lib/libghostty-vt.a"
cp "$FAKE_VT_LIB" "$RELEASE_BUILD_ROOT/vt/lib/$FAKE_VT_LIB_NAME"

tar -C "$RELEASE_BUILD_ROOT/kit" -czf "$RELEASE_DIR/GhosttyKit.xcframework.tar.gz" "GhosttyKit.xcframework"
tar -C "$RELEASE_BUILD_ROOT/resources" -czf "$RELEASE_DIR/GhosttyKit-resources.tar.gz" "ghostty" "terminfo"
tar -C "$RELEASE_BUILD_ROOT/vt" -czf "$RELEASE_DIR/libghostty-vt.tar.gz" "include" "lib"

# The fixture's build_script_version comes from the script under test: it is part of the artifact
# key, so a hardcoded copy would go stale on the next bump and stop the release fixture from
# validating at all.
BUILD_SCRIPT_VERSION="$(sed -n 's/^BUILD_SCRIPT_VERSION="\(.*\)"$/\1/p' "$SOURCE_SETUP_SCRIPT" | head -n 1)"
[[ -n "$BUILD_SCRIPT_VERSION" ]] || fail "could not read BUILD_SCRIPT_VERSION from setup_ghostty.sh"

# host_arch is the real host architecture for the same reason: it is part of the artifact key, so a
# placeholder would make this release fail validation on every run instead of installing cleanly.
python3 - "$RELEASE_DIR" "$GHOSTTY_SHA" "$BUILD_SCRIPT_VERSION" "$ARCH" <<'PY'
import hashlib
import json
import pathlib
import sys

release_dir = pathlib.Path(sys.argv[1])
ghostty_sha = sys.argv[2]
build_script_version = int(sys.argv[3])
host_arch = sys.argv[4]
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
    "zig_version": "0.16.0",
    "build_script_version": build_script_version,
    "xcode_version": "17.0",
    "xcode_build_version": "17C52",
    "swift_version": "Swift release fixture",
    "host_arch": host_arch,
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
    "SPACES_GHOSTTY_CACHE_DIR=$CACHE_DIR"
    "SPACES_TEST_BUILD_LOG=$BUILD_LOG"
    "SPACES_TEST_RELEASE_DIR=$RELEASE_DIR"
    "SPACES_TEST_ZIG_CACHE_DIR=$ZIG_CACHE_DIR"
    "SPACES_TEST_GH_LOG=$GH_LOG"
    "SPACES_TEST_FAKE_VT_LIB=$FAKE_VT_LIB"
    "SPACES_TEST_FAKE_VT_LIB_NAME=$FAKE_VT_LIB_NAME"
)

# The cache entry directory carries the whole validity key, so two checkouts that disagree on any
# of it occupy different entries instead of evicting each other (scenario 10). The version fields
# come from the script under test for the same reason the release fixture reads them: a hardcoded
# copy would go stale on the next bump.
MANIFEST_SCHEMA_VERSION="$(sed -n 's/^MANIFEST_SCHEMA_VERSION="\(.*\)"$/\1/p' "$SOURCE_SETUP_SCRIPT" | head -n 1)"
[[ -n "$MANIFEST_SCHEMA_VERSION" ]] || fail "could not read MANIFEST_SCHEMA_VERSION from setup_ghostty.sh"
ZIG_VERSION="$(sed -n 's/^ZIG_VERSION="\(.*\)"$/\1/p' "$SOURCE_SETUP_SCRIPT" | head -n 1)"
[[ -n "$ZIG_VERSION" ]] || fail "could not read ZIG_VERSION from setup_ghostty.sh"

CACHE_KEY_LEAF="schema=$MANIFEST_SCHEMA_VERSION-script=$BUILD_SCRIPT_VERSION-zig=$ZIG_VERSION-xcode=17C52-opt=ReleaseFast-arch=$ARCH"
CACHE_ENTRY="$CACHE_DIR/$GHOSTTY_SHA/$CACHE_KEY_LEAF"

# --- 1. Seed: a download installs artifacts and populates the shared cache. ---
: > "$GH_LOG"
if ! env "${SETUP_ENV[@]}" "$TEMP_APP_ROOT/scripts/setup_ghostty.sh" --download-only > "$TMP_ROOT/seed.out" 2>&1; then
    fail "seed download-only setup failed"
fi

grep -q "Saving Ghostty artifacts to cache" "$TMP_ROOT/seed.out" || fail "seed run did not report saving to cache"
[[ -d "$CACHE_ENTRY/ghosttykit/GhosttyKit.xcframework" ]] || fail "cache entry missing GhosttyKit"
[[ -f "$CACHE_ENTRY/ghosttyvt/include/ghostty/vt.h" ]] || fail "cache entry missing libghostty-vt header"
[[ -f "$CACHE_ENTRY/ghostty-artifacts/manifest.json" ]] || fail "cache entry missing manifest"
# The heavy Zig toolchain must not be cached.
[[ ! -d "$CACHE_ENTRY/ghosttyvt/toolchain" ]] || fail "cache entry should not contain the Zig toolchain"

# --- 1b. Empty submodule directories resolve the gitlink SHA, not the parent repo HEAD. ---
EMPTY_REPO="$TMP_ROOT/empty-submodule-repo"
EMPTY_APP_ROOT="$EMPTY_REPO/apps/macos"
EMPTY_GHOSTTY_ROOT="$EMPTY_APP_ROOT/vendor/ghostty"
mkdir -p "$EMPTY_APP_ROOT/scripts" "$EMPTY_GHOSTTY_ROOT"
cp "$SOURCE_SETUP_SCRIPT" "$EMPTY_APP_ROOT/scripts/setup_ghostty.sh"
chmod +x "$EMPTY_APP_ROOT/scripts/setup_ghostty.sh"

git -C "$EMPTY_REPO" init -q
git -C "$EMPTY_REPO" config user.email "spaces-test@example.com"
git -C "$EMPTY_REPO" config user.name "Spaces Test"
git -C "$EMPTY_REPO" config commit.gpgsign false
: > "$EMPTY_REPO/README.md"
git -C "$EMPTY_REPO" add README.md
git -C "$EMPTY_REPO" -c commit.gpgsign=false commit -q -m "Create parent fixture"
PARENT_SHA="$(git -C "$EMPTY_REPO" rev-parse HEAD)"
[[ "$PARENT_SHA" != "$GHOSTTY_SHA" ]] || fail "parent fixture SHA unexpectedly matched Ghostty SHA"
git -C "$EMPTY_REPO" update-index --add --cacheinfo 160000 "$GHOSTTY_SHA" apps/macos/vendor/ghostty

: > "$GH_LOG"
if ! env "${SETUP_ENV[@]}" "SPACES_TEST_GH_FAIL=1" \
    "$EMPTY_APP_ROOT/scripts/setup_ghostty.sh" > "$TMP_ROOT/empty-submodule.out" 2>&1; then
    fail "empty-submodule setup failed (should have used the gitlink SHA cache entry)"
fi

grep -q "Restoring Ghostty artifacts from cache" "$TMP_ROOT/empty-submodule.out" \
    || fail "empty-submodule run did not report a cache restore"
grep -q "ghostty sha: $GHOSTTY_SHA" "$TMP_ROOT/empty-submodule.out" \
    || fail "empty-submodule run did not resolve the Ghostty gitlink SHA"
if grep -q "$PARENT_SHA" "$TMP_ROOT/empty-submodule.out"; then
    fail "empty-submodule run used the parent repo HEAD as the Ghostty SHA"
fi
if [[ -s "$GH_LOG" ]]; then
    fail "empty-submodule run invoked gh despite a valid cache entry"
fi
[[ -d "$EMPTY_APP_ROOT/.local/ghosttykit/GhosttyKit.xcframework" ]] || fail "empty-submodule restore did not install GhosttyKit"
[[ -f "$EMPTY_APP_ROOT/.local/ghosttyvt/include/ghostty/vt.h" ]] || fail "empty-submodule restore did not install libghostty-vt header"

# --- 2. Restore: a fresh, empty .local restores from cache without the network. ---
rm -rf "$TEMP_APP_ROOT/.local"
: > "$GH_LOG"
if ! env "${SETUP_ENV[@]}" "SPACES_TEST_GH_FAIL=1" "$TEMP_APP_ROOT/scripts/setup_ghostty.sh" > "$TMP_ROOT/restore.out" 2>&1; then
    fail "restore setup failed (should have used the cache, not the network)"
fi

grep -q "Restoring Ghostty artifacts from cache" "$TMP_ROOT/restore.out" || fail "restore run did not report a cache restore"
if [[ -s "$GH_LOG" ]]; then
    fail "restore run invoked gh despite a valid cache entry"
fi
if grep -q "Downloading Ghostty artifacts" "$TMP_ROOT/restore.out"; then
    fail "restore run attempted a download despite a valid cache entry"
fi
[[ -d "$TEMP_APP_ROOT/.local/ghosttykit/GhosttyKit.xcframework" ]] || fail "restore did not install GhosttyKit into .local"
[[ -f "$TEMP_APP_ROOT/.local/ghosttyvt/include/ghostty/vt.h" ]] || fail "restore did not install libghostty-vt header into .local"

# --- 2b. Local artifacts with a matching manifest but no runtime dylib are not reused. ---
rm -f "$TEMP_APP_ROOT/.local/ghosttyvt/lib/$FAKE_VT_LIB_NAME"
: > "$GH_LOG"
if ! env "${SETUP_ENV[@]}" "SPACES_TEST_GH_FAIL=1" "$TEMP_APP_ROOT/scripts/setup_ghostty.sh" > "$TMP_ROOT/missing-runtime.out" 2>&1; then
    fail "missing-runtime setup failed (should have restored from cache)"
fi
grep -q "Local Ghostty artifacts are incomplete or not loadable" "$TMP_ROOT/missing-runtime.out" \
    || fail "missing-runtime run did not reject local artifacts"
grep -q "Restoring Ghostty artifacts from cache" "$TMP_ROOT/missing-runtime.out" \
    || fail "missing-runtime run did not restore from cache"

# --- 3. A stale cache entry for the same key is replaced, not kept. ---
# Corrupt the cached manifest so it no longer matches the validation inputs
# (as a setup-script/Zig/schema bump on the same SHA/Xcode/arch would). The
# restore must reject it, the download must install fresh artifacts, and the
# trailing save must replace the stale entry rather than leave it in place.
python3 - "$CACHE_ENTRY/ghostty-artifacts/manifest.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["build_script_version"] = 99
path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

rm -rf "$TEMP_APP_ROOT/.local"
: > "$GH_LOG"
if ! env "${SETUP_ENV[@]}" "$TEMP_APP_ROOT/scripts/setup_ghostty.sh" > "$TMP_ROOT/stale.out" 2>&1; then
    fail "stale-entry setup failed"
fi

grep -q "Replacing stale Ghostty cache entry" "$TMP_ROOT/stale.out" || fail "stale entry was not reported as replaced"
[[ -s "$GH_LOG" ]] || fail "stale-entry run should have downloaded fresh artifacts"
STALE_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build_script_version"])' "$CACHE_ENTRY/ghostty-artifacts/manifest.json")"
[[ "$STALE_VERSION" == "$BUILD_SCRIPT_VERSION" ]] || fail "stale cache entry was not replaced with current artifacts (build_script_version=$STALE_VERSION)"

# --- 4. Dirty builds stay local and never reach the shared cache. ---
DIRTY_CACHE_DIR="$TMP_ROOT/cache-dirty"
mkdir -p "$DIRTY_CACHE_DIR"
rm -rf "$TEMP_APP_ROOT/.local"
place_fake_zig
: > "$BUILD_LOG"
touch "$TEMP_GHOSTTY_ROOT/local-dirty-change"

if ! env "${SETUP_ENV[@]}" "SPACES_GHOSTTY_CACHE_DIR=$DIRTY_CACHE_DIR" \
    "$TEMP_APP_ROOT/scripts/setup_ghostty.sh" --build --allow-dirty > "$TMP_ROOT/dirty-build.out" 2>&1; then
    fail "dirty --build --allow-dirty setup failed"
fi

rm -f "$TEMP_GHOSTTY_ROOT/local-dirty-change"

[[ -f "$TEMP_APP_ROOT/.local/ghostty-artifacts/manifest.json" ]] || fail "dirty build did not install artifacts locally"
if find "$DIRTY_CACHE_DIR" -mindepth 1 -not -name '.*' | grep -q .; then
    fail "dirty build polluted the shared cache"
fi
grep -q "Saving Ghostty artifacts to cache" "$TMP_ROOT/dirty-build.out" && fail "dirty build reported saving to cache"

# --- 5. A cache publish that cannot be written warns but does not fail setup. ---
# Plant a file where the per-SHA cache directory must be created so the publish
# fails. Setup must still install the artifacts and exit 0, with a warning.
BROKEN_CACHE_DIR="$TMP_ROOT/cache-broken"
mkdir -p "$BROKEN_CACHE_DIR"
: > "$BROKEN_CACHE_DIR/$GHOSTTY_SHA"
rm -rf "$TEMP_APP_ROOT/.local"
: > "$GH_LOG"
if ! env "${SETUP_ENV[@]}" "SPACES_GHOSTTY_CACHE_DIR=$BROKEN_CACHE_DIR" \
    "$TEMP_APP_ROOT/scripts/setup_ghostty.sh" > "$TMP_ROOT/broken.out" 2>&1; then
    fail "setup should still succeed when the cache cannot be published"
fi

grep -q "could not populate Ghostty artifact cache" "$TMP_ROOT/broken.out" || fail "broken cache publish did not warn"
[[ -d "$TEMP_APP_ROOT/.local/ghosttykit/GhosttyKit.xcframework" ]] || fail "artifacts were not installed despite the cache publish failure"

# --- 6. A Debug run rejects the released ReleaseFast variant and builds locally. ---
# The release fixture (and the seeded cache) are ReleaseFast. A Debug setup keys
# to a different cache entry, so it misses local/cache, downloads, detects the
# build-optimize mismatch, and builds from source for Debug instead of
# installing (and then forever re-rejecting) the ReleaseFast artifacts.
git -C "$TEMP_GHOSTTY_ROOT" clean -fdx >/dev/null 2>&1
rm -rf "$TEMP_APP_ROOT/.local"
place_fake_zig
: > "$GH_LOG"
: > "$BUILD_LOG"
if ! env "${SETUP_ENV[@]}" "SPACES_GHOSTTY_BUILD_OPTIMIZE=Debug" \
    "$TEMP_APP_ROOT/scripts/setup_ghostty.sh" > "$TMP_ROOT/optimize.out" 2>&1; then
    fail "Debug setup failed"
fi

if grep -q "Restoring Ghostty artifacts from cache" "$TMP_ROOT/optimize.out"; then
    fail "Debug setup restored the default-optimize cache entry"
fi
grep -q "different build-optimize mode; building locally instead" "$TMP_ROOT/optimize.out" \
    || fail "Debug setup did not build locally on the optimize mismatch"
[[ -s "$BUILD_LOG" ]] || fail "Debug setup did not invoke the local build"
DEBUG_OPTIMIZE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build_optimize"])' "$TEMP_APP_ROOT/.local/ghostty-artifacts/manifest.json")"
[[ "$DEBUG_OPTIMIZE" == "Debug" ]] || fail "Debug build manifest optimize mode is $DEBUG_OPTIMIZE"

# --- 7. With no override, the cache root is the primary checkout, shared by every worktree. ---
# The scenarios above all pin SPACES_GHOSTTY_CACHE_DIR. This one exercises the derivation itself,
# which is what keeps `scripts/verify.sh` inside a worktree from seeding a private multi-gigabyte
# store: a run from a git worktree must read and write the primary checkout's cache.
PRIMARY_REPO="$TMP_ROOT/primary"
PRIMARY_APP_ROOT="$PRIMARY_REPO/apps/macos"
PRIMARY_WORKTREE="$TMP_ROOT/primary-worktree"
mkdir -p "$PRIMARY_APP_ROOT/scripts"
cp "$SOURCE_SETUP_SCRIPT" "$PRIMARY_APP_ROOT/scripts/setup_ghostty.sh"
chmod +x "$PRIMARY_APP_ROOT/scripts/setup_ghostty.sh"

git -C "$PRIMARY_REPO" init -q
git -C "$PRIMARY_REPO" config user.email "spaces-test@example.com"
git -C "$PRIMARY_REPO" config user.name "Spaces Test"
git -C "$PRIMARY_REPO" config commit.gpgsign false
git -C "$PRIMARY_REPO" add apps/macos/scripts/setup_ghostty.sh
git -C "$PRIMARY_REPO" update-index --add --cacheinfo 160000 "$GHOSTTY_SHA" apps/macos/vendor/ghostty
git -C "$PRIMARY_REPO" -c commit.gpgsign=false commit -q -m "Create primary checkout fixture"
git -C "$PRIMARY_REPO" worktree add -q -b fixture-worktree "$PRIMARY_WORKTREE"

DERIVED_ENV=(
    "PATH=$STUB_BIN:$PATH"
    "SPACES_GHOSTTY_SETUP_SKIP_API_VERIFY=1"
    "SPACES_TEST_BUILD_LOG=$BUILD_LOG"
    "SPACES_TEST_RELEASE_DIR=$RELEASE_DIR"
    "SPACES_TEST_ZIG_CACHE_DIR=$ZIG_CACHE_DIR"
    "SPACES_TEST_GH_LOG=$GH_LOG"
    "SPACES_TEST_FAKE_VT_LIB=$FAKE_VT_LIB"
    "SPACES_TEST_FAKE_VT_LIB_NAME=$FAKE_VT_LIB_NAME"
)

: > "$GH_LOG"
if ! env "${DERIVED_ENV[@]}" \
    "$PRIMARY_WORKTREE/apps/macos/scripts/setup_ghostty.sh" --download-only > "$TMP_ROOT/derived-cache.out" 2>&1; then
    fail "worktree setup with a derived cache root failed"
fi

DERIVED_ENTRY="$PRIMARY_APP_ROOT/.local/ghostty-cache/$GHOSTTY_SHA/$CACHE_KEY_LEAF"
[[ -f "$DERIVED_ENTRY/ghostty-artifacts/manifest.json" ]] \
    || fail "worktree run did not seed the primary checkout's cache"
[[ ! -d "$PRIMARY_WORKTREE/apps/macos/.local/ghostty-cache" ]] \
    || fail "worktree run seeded a private per-worktree cache"
# Artifacts still install into the running tree; only the cache is shared.
[[ -d "$PRIMARY_WORKTREE/apps/macos/.local/ghosttykit/GhosttyKit.xcframework" ]] \
    || fail "worktree run did not install artifacts into its own .local"

# A second worktree restores that entry instead of going back to the network.
SECOND_WORKTREE="$TMP_ROOT/primary-worktree-2"
git -C "$PRIMARY_REPO" worktree add -q -b fixture-worktree-2 "$SECOND_WORKTREE"
: > "$GH_LOG"
if ! env "${DERIVED_ENV[@]}" "SPACES_TEST_GH_FAIL=1" \
    "$SECOND_WORKTREE/apps/macos/scripts/setup_ghostty.sh" > "$TMP_ROOT/derived-restore.out" 2>&1; then
    fail "second worktree did not restore from the shared cache"
fi
grep -q "Restoring Ghostty artifacts from cache" "$TMP_ROOT/derived-restore.out" \
    || fail "second worktree did not report a cache restore"

# A plain checkout with no worktrees -- the shape CI runs -- resolves to itself. The forced gh
# failure means the only way this can succeed is by finding the entry the worktree seeded.
: > "$GH_LOG"
if ! env "${DERIVED_ENV[@]}" "SPACES_TEST_GH_FAIL=1" \
    "$PRIMARY_APP_ROOT/scripts/setup_ghostty.sh" > "$TMP_ROOT/derived-primary.out" 2>&1; then
    fail "primary checkout did not restore from its own cache"
fi
grep -q "Restoring Ghostty artifacts from cache" "$TMP_ROOT/derived-primary.out" \
    || fail "primary checkout did not resolve the cache to itself"
[[ -d "$PRIMARY_APP_ROOT/.local/ghosttykit/GhosttyKit.xcframework" ]] \
    || fail "primary checkout restore did not install GhosttyKit"

# --- 8. Outside a Git checkout the derivation fails loudly instead of guessing. ---
# A silent per-tree cache would look like a working cache while every tree stored its own copy,
# so the missing checkout has to surface as an error.
rm -rf "$TEMP_APP_ROOT/.local"
set +e
env "${DERIVED_ENV[@]}" "$TEMP_APP_ROOT/scripts/setup_ghostty.sh" --download-only \
    > "$TMP_ROOT/no-checkout.out" 2>&1
NO_CHECKOUT_STATUS=$?
set -e

[[ "$NO_CHECKOUT_STATUS" -ne 0 ]] || fail "setup outside a Git checkout should not succeed"
grep -q "unable to locate the primary checkout for the shared Ghostty artifact cache" "$TMP_ROOT/no-checkout.out" \
    || fail "setup outside a Git checkout did not explain the missing primary checkout"

# --- 9. Artifacts recorded for another architecture are rejected on every reuse path. ---
# libghostty-vt is a host-native dynamic library, so artifacts built on another architecture would
# unpack, pass the Mach-O presence check, and only fail when something loaded the library. The
# architecture is part of the artifact key for that reason, and both key checks have to enforce it:
# the download validation below, and the installed-manifest reuse check after it.
if [[ "$ARCH" == "arm64" ]]; then
    FOREIGN_ARCH="x86_64"
else
    FOREIGN_ARCH="arm64"
fi

FOREIGN_RELEASE_DIR="$TMP_ROOT/release-foreign-arch"
FOREIGN_CACHE_DIR="$TMP_ROOT/cache-foreign-arch"
mkdir -p "$FOREIGN_RELEASE_DIR" "$FOREIGN_CACHE_DIR"
cp "$RELEASE_DIR"/*.tar.gz "$FOREIGN_RELEASE_DIR"/

rewrite_manifest_host_arch() {
    python3 - "$1" "$2" "$3" <<'PY'
import json
import pathlib
import sys

source, dest, host_arch = sys.argv[1:4]
manifest = json.loads(pathlib.Path(source).read_text(encoding="utf-8"))
manifest["host_arch"] = host_arch
pathlib.Path(dest).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

rewrite_manifest_host_arch "$RELEASE_DIR/manifest.json" "$FOREIGN_RELEASE_DIR/manifest.json" "$FOREIGN_ARCH"
(
    cd "$FOREIGN_RELEASE_DIR"
    shasum -a 256 \
        "GhosttyKit.xcframework.tar.gz" \
        "GhosttyKit-resources.tar.gz" \
        "libghostty-vt.tar.gz" \
        "manifest.json" > "SHA256SUMS"
)

git -C "$TEMP_GHOSTTY_ROOT" clean -fdx >/dev/null 2>&1
rm -rf "$TEMP_APP_ROOT/.local"
place_fake_zig
: > "$GH_LOG"
: > "$BUILD_LOG"
if ! env "${SETUP_ENV[@]}" \
    "SPACES_TEST_RELEASE_DIR=$FOREIGN_RELEASE_DIR" \
    "SPACES_GHOSTTY_CACHE_DIR=$FOREIGN_CACHE_DIR" \
    "$TEMP_APP_ROOT/scripts/setup_ghostty.sh" > "$TMP_ROOT/foreign-arch.out" 2>&1; then
    fail "foreign-architecture setup failed"
fi

grep -q "different host architecture; building locally instead" "$TMP_ROOT/foreign-arch.out" \
    || fail "foreign-architecture download was not rejected in favour of a local build"
[[ -s "$BUILD_LOG" ]] || fail "foreign-architecture setup did not invoke the local build"
INSTALLED_ARCH="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["host_arch"])' \
    "$TEMP_APP_ROOT/.local/ghostty-artifacts/manifest.json")"
[[ "$INSTALLED_ARCH" == "$ARCH" ]] || fail "installed manifest records host_arch $INSTALLED_ARCH, not $ARCH"

# Installed artifacts recorded for another architecture are not reused either. With the network
# stubbed to fail and an empty cache, the only way this run can succeed is by reusing them.
EMPTY_CACHE_DIR="$TMP_ROOT/cache-foreign-arch-reuse"
rewrite_manifest_host_arch \
    "$TEMP_APP_ROOT/.local/ghostty-artifacts/manifest.json" \
    "$TEMP_APP_ROOT/.local/ghostty-artifacts/manifest.json" \
    "$FOREIGN_ARCH"
: > "$GH_LOG"
set +e
env "${SETUP_ENV[@]}" "SPACES_TEST_GH_FAIL=1" "SPACES_GHOSTTY_CACHE_DIR=$EMPTY_CACHE_DIR" \
    "$TEMP_APP_ROOT/scripts/setup_ghostty.sh" > "$TMP_ROOT/foreign-arch-reuse.out" 2>&1
FOREIGN_REUSE_STATUS=$?
set -e

[[ "$FOREIGN_REUSE_STATUS" -ne 0 ]] || fail "setup reused installed artifacts recorded for another architecture"
grep -q "Local Ghostty artifact manifest does not match current Ghostty setup inputs" \
    "$TMP_ROOT/foreign-arch-reuse.out" || fail "foreign-architecture local artifacts were not rejected by the manifest check"

# --- 10. Checkouts that agree on SHA/Xcode/arch/optimize but differ in a manifest-only input
#         keep separate cache entries instead of evicting each other. ---
# Several worktrees are checked out at once here, and a branch that bumps BUILD_SCRIPT_VERSION (or
# the pinned Zig, or the manifest schema) is ordinary. Every input the manifest check compares has
# to be part of the cache key: when it was not, both checkouts resolved to one entry path, each
# judged the other's artifacts stale, and they evicted and re-seeded the same key forever -- both
# rebuilding or redownloading multi-gigabyte artifacts while appearing to share a cache.
COEXIST_CACHE_DIR="$TMP_ROOT/cache-coexist"
CURRENT_CHECKOUT="$TMP_ROOT/coexist-current"
BUMPED_CHECKOUT="$TMP_ROOT/coexist-bumped"
BUMPED_BUILD_SCRIPT_VERSION="$((BUILD_SCRIPT_VERSION + 1))"
mkdir -p "$COEXIST_CACHE_DIR"

# A fixture checkout running setup_ghostty.sh with the given BUILD_SCRIPT_VERSION. The Ghostty
# submodule is left empty so the pinned SHA comes from the gitlink, which keeps both checkouts on
# the same Ghostty SHA without a second submodule clone.
make_coexist_checkout() {
    local root="$1"
    local build_script_version="$2"
    local app_root="$root/apps/macos"

    mkdir -p "$app_root/scripts" "$app_root/vendor/ghostty"
    sed "s/^BUILD_SCRIPT_VERSION=\".*\"\$/BUILD_SCRIPT_VERSION=\"$build_script_version\"/" \
        "$SOURCE_SETUP_SCRIPT" > "$app_root/scripts/setup_ghostty.sh"
    chmod +x "$app_root/scripts/setup_ghostty.sh"
    grep -q "^BUILD_SCRIPT_VERSION=\"$build_script_version\"\$" "$app_root/scripts/setup_ghostty.sh" \
        || fail "could not pin BUILD_SCRIPT_VERSION=$build_script_version in the fixture checkout"

    git -C "$root" init -q
    git -C "$root" config user.email "spaces-test@example.com"
    git -C "$root" config user.name "Spaces Test"
    git -C "$root" config commit.gpgsign false
    git -C "$root" add apps/macos/scripts/setup_ghostty.sh
    git -C "$root" update-index --add --cacheinfo 160000 "$GHOSTTY_SHA" apps/macos/vendor/ghostty
    git -C "$root" -c commit.gpgsign=false commit -q -m "Create coexisting checkout fixture"
}

make_coexist_checkout "$CURRENT_CHECKOUT" "$BUILD_SCRIPT_VERSION"
make_coexist_checkout "$BUMPED_CHECKOUT" "$BUMPED_BUILD_SCRIPT_VERSION"

# The bumped checkout needs a release built by its own setup script; the shared fixture release
# carries the current version and would be rejected before it ever reached the cache.
BUMPED_RELEASE_DIR="$TMP_ROOT/release-bumped-script"
mkdir -p "$BUMPED_RELEASE_DIR"
cp "$RELEASE_DIR"/*.tar.gz "$BUMPED_RELEASE_DIR"/
python3 - "$RELEASE_DIR/manifest.json" "$BUMPED_RELEASE_DIR/manifest.json" "$BUMPED_BUILD_SCRIPT_VERSION" <<'PY'
import json
import pathlib
import sys

source, dest, build_script_version = sys.argv[1:4]
manifest = json.loads(pathlib.Path(source).read_text(encoding="utf-8"))
manifest["build_script_version"] = int(build_script_version)
pathlib.Path(dest).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
(
    cd "$BUMPED_RELEASE_DIR"
    shasum -a 256 \
        "GhosttyKit.xcframework.tar.gz" \
        "GhosttyKit-resources.tar.gz" \
        "libghostty-vt.tar.gz" \
        "manifest.json" > "SHA256SUMS"
)

: > "$GH_LOG"
if ! env "${SETUP_ENV[@]}" "SPACES_GHOSTTY_CACHE_DIR=$COEXIST_CACHE_DIR" \
    "$CURRENT_CHECKOUT/apps/macos/scripts/setup_ghostty.sh" --download-only \
    > "$TMP_ROOT/coexist-current-seed.out" 2>&1; then
    fail "current-version checkout failed to seed the shared cache"
fi

if ! env "${SETUP_ENV[@]}" "SPACES_GHOSTTY_CACHE_DIR=$COEXIST_CACHE_DIR" \
    "SPACES_TEST_RELEASE_DIR=$BUMPED_RELEASE_DIR" \
    "$BUMPED_CHECKOUT/apps/macos/scripts/setup_ghostty.sh" --download-only \
    > "$TMP_ROOT/coexist-bumped-seed.out" 2>&1; then
    fail "bumped-version checkout failed to seed the shared cache"
fi

if grep -q "Replacing stale Ghostty cache entry" "$TMP_ROOT/coexist-bumped-seed.out"; then
    fail "bumped-version checkout evicted the current-version checkout's cache entry"
fi

COEXIST_ENTRIES="$(find "$COEXIST_CACHE_DIR/$GHOSTTY_SHA" -mindepth 1 -maxdepth 1 -type d -not -name '.*' | sort)"
COEXIST_ENTRY_COUNT="$(printf '%s\n' "$COEXIST_ENTRIES" | grep -c . || true)"
[[ "$COEXIST_ENTRY_COUNT" == "2" ]] \
    || fail "expected 2 coexisting cache entries, found $COEXIST_ENTRY_COUNT: $COEXIST_ENTRIES"

COEXIST_VERSIONS="$(
    while IFS= read -r entry; do
        python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build_script_version"])' \
            "$entry/ghostty-artifacts/manifest.json"
    done <<< "$COEXIST_ENTRIES" | sort -n | tr '\n' ' '
)"
[[ "$COEXIST_VERSIONS" == "$BUILD_SCRIPT_VERSION $BUMPED_BUILD_SCRIPT_VERSION " ]] \
    || fail "cache entries do not cover both build script versions: $COEXIST_VERSIONS"

# Both checkouts must restore their own entry from the shared cache. The forced gh failure means a
# run that lost its entry cannot recover by downloading.
rm -rf "$CURRENT_CHECKOUT/apps/macos/.local" "$BUMPED_CHECKOUT/apps/macos/.local"
: > "$GH_LOG"
if ! env "${SETUP_ENV[@]}" "SPACES_GHOSTTY_CACHE_DIR=$COEXIST_CACHE_DIR" "SPACES_TEST_GH_FAIL=1" \
    "$CURRENT_CHECKOUT/apps/macos/scripts/setup_ghostty.sh" \
    > "$TMP_ROOT/coexist-current-restore.out" 2>&1; then
    fail "current-version checkout could not restore its cache entry"
fi
grep -q "Restoring Ghostty artifacts from cache" "$TMP_ROOT/coexist-current-restore.out" \
    || fail "current-version checkout did not report a cache restore"
RESTORED_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build_script_version"])' \
    "$CURRENT_CHECKOUT/apps/macos/.local/ghostty-artifacts/manifest.json")"
[[ "$RESTORED_VERSION" == "$BUILD_SCRIPT_VERSION" ]] \
    || fail "current-version checkout restored artifacts built by script version $RESTORED_VERSION"

if ! env "${SETUP_ENV[@]}" "SPACES_GHOSTTY_CACHE_DIR=$COEXIST_CACHE_DIR" "SPACES_TEST_GH_FAIL=1" \
    "$BUMPED_CHECKOUT/apps/macos/scripts/setup_ghostty.sh" \
    > "$TMP_ROOT/coexist-bumped-restore.out" 2>&1; then
    fail "bumped-version checkout could not restore its cache entry"
fi
grep -q "Restoring Ghostty artifacts from cache" "$TMP_ROOT/coexist-bumped-restore.out" \
    || fail "bumped-version checkout did not report a cache restore"
RESTORED_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build_script_version"])' \
    "$BUMPED_CHECKOUT/apps/macos/.local/ghostty-artifacts/manifest.json")"
[[ "$RESTORED_VERSION" == "$BUMPED_BUILD_SCRIPT_VERSION" ]] \
    || fail "bumped-version checkout restored artifacts built by script version $RESTORED_VERSION"

echo "setup_ghostty cache restore test passed"
