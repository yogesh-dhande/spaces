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
# Bump whenever the Ghostty build flags below change. The manifest records no
# build flags and the artifact release is keyed on the Ghostty SHA alone, so
# this is the only thing that invalidates artifacts built with older flags.
BUILD_SCRIPT_VERSION="3"
MANIFEST_SCHEMA_VERSION="2"
VALIDATION_XCODE_BUILD_MISMATCH=42
VALIDATION_OPTIMIZE_MISMATCH=43
VALIDATION_HOST_ARCH_MISMATCH=44

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

ZIG_VERSION="0.16.0"
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

# Git hooks export repository-local variables for the superproject. Those variables take
# precedence over `git -C`, including when the target is the Ghostty submodule, so an inherited
# GIT_DIR can make a submodule query return the Spaces commit instead. This script is always a
# child process, so clearing Git's complete local-environment set cannot affect the calling Git
# command or shell.
while IFS= read -r git_local_variable; do
    [[ -n "$git_local_variable" ]] && unset "$git_local_variable"
done < <(git rev-parse --local-env-vars)

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

submodule_is_initialized() {
    [[ -e "$GHOSTTY_SOURCE_ROOT/.git" ]] || return 1
    git -C "$GHOSTTY_SOURCE_ROOT" rev-parse --git-dir >/dev/null 2>&1
}

resolve_ghostty_sha() {
    if submodule_is_initialized; then
        git -C "$GHOSTTY_SOURCE_ROOT" rev-parse HEAD
        return
    fi

    git -C "$REPO_ROOT" ls-files -s -- "$SUBMODULE_PATH" | awk '$1 == "160000" { print $2; exit }'
}

# The checkout that owns this repository's Git directory. For a git worktree that
# is the primary checkout, and for a plain clone it is the clone itself. The
# shared artifact cache is rooted there so every worktree on a machine reads and
# writes one store.
#
# Dies rather than picking a per-tree location when the derivation fails: this
# script already requires a Git checkout to resolve the pinned Ghostty commit
# from the submodule gitlink, and a silent per-tree cache is exactly the bug this
# derivation exists to prevent -- it would look like a working cache while every
# worktree rebuilt and stored its own multi-gigabyte copy.
primary_checkout_dir() {
    local common_git_dir
    common_git_dir="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
        || die "unable to locate the primary checkout for the shared Ghostty artifact cache: $REPO_ROOT is not a Git checkout"
    [[ "$(basename "$common_git_dir")" == ".git" ]] \
        || die "unable to locate the primary checkout for the shared Ghostty artifact cache: unexpected Git common directory $common_git_dir"
    (cd "$common_git_dir/.." && pwd)
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

# The host architecture the artifacts are built for. libghostty-vt is a
# host-native dynamic library, so an artifact built on another architecture
# cannot be loaded here. Every producer and consumer of the architecture -- the
# manifest writer, the cache key, and both reuse-key checks -- goes through this
# one function so a recorded architecture and a checked architecture can never
# be derived differently.
current_host_arch() {
    uname -m
}

require_metal_toolchain() {
    [[ "$(uname -s)" == "Darwin" ]] || return 0
    command_exists xcrun || die "Xcode command-line tool 'xcrun' is required to build Ghostty artifacts"

    local tmp_dir output
    tmp_dir="$(mktemp -d)"
    printf 'kernel void spaces_metal_toolchain_probe() {}\n' > "$tmp_dir/probe.metal"
    if output="$(xcrun -sdk macosx metal -c "$tmp_dir/probe.metal" -o "$tmp_dir/probe.ir" 2>&1)"; then
        rm -rf "$tmp_dir"
        return
    fi
    rm -rf "$tmp_dir"

    printf '%s\n' "$output" >&2
    die "Xcode's Metal Toolchain component is required to build Ghostty artifacts. Run 'xcodebuild -downloadComponent MetalToolchain' and retry. If Xcode reports that first-launch packages need authorization, run 'sudo xcodebuild -runFirstLaunch' first."
}

artifact_release_tag() {
    printf "%s%s\n" "$ARTIFACT_RELEASE_PREFIX" "$GHOSTTY_SHA"
}

# The single definition of what an artifact set must agree on to be reusable in
# this checkout. Both consumers derive from this one list:
#
#   * manifest_matches_current_sha  -- validates an installed or cached manifest
#   * cache_entry_dir               -- builds the shared cache path
#
# Deriving both from one definition is the point. When the cache key covered
# fewer fields than the validity check, two checkouts that differed only in an
# unkeyed field (a BUILD_SCRIPT_VERSION bump, say) resolved to the same entry
# path, each judged the other's artifacts stale, and they evicted and re-seeded
# that key in a loop -- both rebuilding or redownloading multi-gigabyte artifacts
# while appearing to share a cache. Adding a field here keys it and checks it
# together, so the two can never drift apart again.
#
# Each line is "<manifest field>|<json type>|<key label>|<value>":
#   json type - how the value compares against the parsed manifest; write_manifest
#               records the two version counters as JSON numbers and the rest as
#               strings.
#   key label - short name this field carries in the cache entry directory. The
#               one empty label (ghostty_sha) is keyed as the parent directory of
#               the entry instead, so a cache stays browsable by Ghostty SHA.
#   value     - an empty value means "not determinable here": the manifest check
#               skips the field and the key records "unknown". Only
#               xcode_build_version can be empty, on a host without xcodebuild.
artifact_validity_fields() {
    cat <<EOF
ghostty_sha|str||$GHOSTTY_SHA
schema_version|int|schema|$MANIFEST_SCHEMA_VERSION
build_script_version|int|script|$BUILD_SCRIPT_VERSION
zig_version|str|zig|$ZIG_VERSION
xcode_build_version|str|xcode|$(current_xcode_build_version)
build_optimize|str|opt|$GHOSTTY_BUILD_OPTIMIZE
host_arch|str|arch|$(current_host_arch)
EOF
}

manifest_matches_current_sha() {
    local manifest_path="$1"
    [[ -f "$manifest_path" ]] || return 1

    local -a fields=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        fields+=("$line")
    done < <(artifact_validity_fields)

    python3 - "$manifest_path" "${fields[@]}" <<'PY'
import json
import sys

manifest_path = sys.argv[1]
try:
    with open(manifest_path, "r", encoding="utf-8") as handle:
        manifest = json.load(handle)
except Exception:
    sys.exit(1)

for spec in sys.argv[2:]:
    field, json_type, _label, value = spec.split("|", 3)
    if not value:
        continue
    expected = int(value) if json_type == "int" else value
    if manifest.get(field) != expected:
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
    ghostty_vt_runtime_library_present
}

ghostty_vt_runtime_library_path() {
    case "$(uname -s)" in
        Darwin)
            printf "%s/libghostty-vt.dylib\n" "$GHOSTTYVT_LIB_ROOT"
            ;;
        Linux)
            printf "%s/libghostty-vt.so\n" "$GHOSTTYVT_LIB_ROOT"
            ;;
        *)
            return 1
            ;;
    esac
}

ghostty_vt_runtime_library_present() {
    local library_path description
    library_path="$(ghostty_vt_runtime_library_path)" || return 1
    [[ -f "$library_path" ]] || return 1
    description="$(file -L "$library_path" 2>/dev/null || true)"

    case "$(uname -s)" in
        Darwin)
            grep -Eq 'Mach-O .*dynamically linked shared library' <<<"$description"
            ;;
        Linux)
            grep -Eq 'ELF .* shared object' <<<"$description"
            ;;
        *)
            return 1
            ;;
    esac
}

normalize_ghosttykit_static_library() {
    # Renaming the static library and rewriting the xcframework Info.plist rewrites
    # artifact bytes, so any digest computed for the installed tree is void. Every
    # install path (build, cache restore, download) normalizes before anything
    # digests the result, so this one reset covers all of them.
    INSTALLED_CONTENT_DIGEST=""

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

# One digest over the four artifact trees the manifest's install_paths name, in a
# fixed order: every regular file contributes its path and content, every symlink
# its path and target, with the file list ordered by raw path bytes so the digest
# is reproducible on any host.
#
# This is an INTEGRITY field, deliberately not part of artifact_validity_fields: a
# cache key has to be derivable before the content it names exists, while this can
# only be computed from produced artifacts. It closes the gap that let a poisoned
# artifact set validate forever -- the manifest and the cache key record build
# INPUTS only, so artifacts whose compiled code disagreed with their own headers
# (an ABI skew that still declares every symbol verify_ghosttykit.sh checks) passed
# every trust path until someone rebuilt by hand.
#
# $1 is a ghosttykit root (GhosttyKit.xcframework + Resources), $2 a ghosttyvt root
# (include + lib), so the same function digests an installed .local and a cache
# entry.
artifact_content_digest() {
    python3 - \
        "ghosttykit/GhosttyKit.xcframework=$1/GhosttyKit.xcframework" \
        "ghosttykit/Resources=$1/Resources" \
        "ghosttyvt/include=$2/include" \
        "ghosttyvt/lib=$2/lib" <<'PY'
import hashlib
import os
import sys

CHUNK = 1024 * 1024


def tree_entries(root):
    """Every file and symlink under root as (relative path bytes, kind, path)."""
    found = []
    stack = [(b"", root)]
    while stack:
        rel, path = stack.pop()
        with os.scandir(path) as scan:
            for entry in scan:
                name = os.fsencode(entry.name)
                child_rel = rel + b"/" + name if rel else name
                if entry.is_symlink():
                    found.append((child_rel, b"symlink", entry.path))
                elif entry.is_dir(follow_symlinks=False):
                    stack.append((child_rel, entry.path))
                else:
                    found.append((child_rel, b"file", entry.path))
    found.sort(key=lambda item: item[0])
    return found


digest = hashlib.sha256()
for spec in sys.argv[1:]:
    label, _, root = spec.partition("=")
    if not os.path.isdir(root):
        print(f"missing Ghostty artifact tree: {root}", file=sys.stderr)
        sys.exit(1)

    label_bytes = os.fsencode(label)
    for rel, kind, path in tree_entries(root):
        digest.update(label_bytes + b"/" + rel + b"\0" + kind + b"\0")
        if kind == b"symlink":
            target = os.fsencode(os.readlink(path))
            digest.update(target + b"\0")
            continue
        file_digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(CHUNK), b""):
                file_digest.update(chunk)
        digest.update(file_digest.digest())

print("sha256:" + digest.hexdigest())
PY
}

# Digest of the artifacts installed in apps/macos/.local, computed at most once per
# run. Hashing the artifact trees costs seconds, and the local reuse check and the
# cache publish both need the same answer.
INSTALLED_CONTENT_DIGEST=""

compute_installed_content_digest() {
    [[ -n "$INSTALLED_CONTENT_DIGEST" ]] && return 0
    INSTALLED_CONTENT_DIGEST="$(artifact_content_digest "$GHOSTTYKIT_ROOT" "$GHOSTTYVT_ROOT")"
}

manifest_content_digest() {
    python3 - "$1" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        digest = json.load(handle)["artifact_content_digest"]
except Exception:
    sys.exit(1)

if not digest:
    sys.exit(1)
print(digest)
PY
}

# True when the artifacts installed in .local still hash to what the installed
# manifest recorded for them.
installed_content_matches_manifest() {
    compute_installed_content_digest || return 1
    local recorded
    recorded="$(manifest_content_digest "$LOCAL_MANIFEST")" || return 1
    [[ "$recorded" == "$INSTALLED_CONTENT_DIGEST" ]]
}

# The same check for a shared-cache entry, whose trees sit at the entry root.
cache_entry_content_matches_manifest() {
    local entry="$1"
    local recorded actual
    recorded="$(manifest_content_digest "$entry/ghostty-artifacts/manifest.json")" || return 1
    actual="$(artifact_content_digest "$entry/ghosttykit" "$entry/ghosttyvt")" || return 1
    [[ "$recorded" == "$actual" ]]
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
    if manifest_matches_current_sha "$LOCAL_MANIFEST"; then
        if ! installed_artifacts_present; then
            echo "==> Local Ghostty artifacts are incomplete or not loadable on this platform"
            return 1
        fi

        normalize_ghosttykit_static_library
        if ! installed_content_matches_manifest; then
            echo "==> Local Ghostty artifacts do not match the content digest their manifest records"
            return 1
        fi

        echo "==> Reusing local Ghostty artifacts for $GHOSTTY_SHA"
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

# Keyed cache entry directory: "<root>/<ghostty sha>/<label=value>-...", built
# from every field in artifact_validity_fields. Because the key carries the whole
# validity key, an entry that resolves for this checkout can only be judged stale
# by a checkout that would key somewhere else -- so checkouts on different Xcode
# toolchains, arches, optimize modes, Zig versions, build-script versions, or
# manifest schemas each occupy their own entry and coexist.
#
# Each component is reduced to a single filesystem-safe path segment. Reserving
# "=" for the label boundary means a value can never forge one. The components
# are short by construction (two counters, a Zig version, an Xcode build id, a
# Zig optimize mode, and uname -m), so the entry name stays well inside the
# filesystem's per-component limit; an absurd SPACES_GHOSTTY_BUILD_OPTIMIZE would
# fail the publish's mkdir and surface as the usual cache warning.
cache_key_component() {
    printf '%s' "${1:-unknown}" | tr -c 'A-Za-z0-9._-' '_'
}

cache_entry_dir() {
    local sha="" leaf="" field label value
    # The JSON type column only matters to the manifest comparison; the key uses
    # the raw value, so it is read into the throwaway "_".
    while IFS='|' read -r field _ label value; do
        [[ -n "$field" ]] || continue
        if [[ -z "$label" ]]; then
            sha="$(cache_key_component "$value")"
            continue
        fi
        leaf+="${leaf:+-}$label=$(cache_key_component "$value")"
    done < <(artifact_validity_fields)

    printf "%s/%s/%s\n" "$GHOSTTY_CACHE_ROOT" "$sha" "$leaf"
}

restore_from_cache_if_valid() {
    local entry
    entry="$(cache_entry_dir)"

    if ! manifest_matches_current_sha "$entry/ghostty-artifacts/manifest.json"; then
        return 1
    fi
    if [[ ! -d "$entry/ghosttykit" || ! -d "$entry/ghosttyvt" ]]; then
        return 1
    fi

    # This function runs with errexit disabled (it is called as `if ! ...`), so
    # every step that could fail must be checked explicitly. Otherwise a failed
    # copy or a failed API-contract verification would fall through to the
    # unconditional success return and accept incompatible artifacts.
    echo "==> Restoring Ghostty artifacts from cache ($entry)"
    rm -rf "$GHOSTTYKIT_ROOT" "$GHOSTTYVT_ROOT" "$ARTIFACT_STATE_ROOT"
    if ! mkdir -p "$LOCAL_ROOT" \
        || ! cp -R "$entry/ghosttykit" "$GHOSTTYKIT_ROOT" \
        || ! cp -R "$entry/ghosttyvt" "$GHOSTTYVT_ROOT" \
        || ! cp -R "$entry/ghostty-artifacts" "$ARTIFACT_STATE_ROOT"; then
        echo "==> Failed to copy cached Ghostty artifacts; falling through to download"
        return 1
    fi

    if ! installed_artifacts_present; then
        echo "==> Cached Ghostty artifacts are incomplete; falling through to download"
        return 1
    fi

    normalize_ghosttykit_static_library
    if ! installed_content_matches_manifest; then
        echo "==> Cached Ghostty artifacts do not match the content digest their manifest records; falling through to download"
        return 1
    fi

    if ! verify_ghosttykit_contract; then
        echo "==> Cached Ghostty artifacts failed API contract verification; falling through to download"
        return 1
    fi
    return 0
}

# Populate the shared cache from the freshly installed .local. Gated on a valid,
# clean, current manifest so dirty/experimental builds never reach the shared
# store. A still-valid entry for the key is left untouched; a stale one is
# replaced. Only the artifact subtrees are cached (not the Zig toolchain or
# source checkout under ghosttyvt).
save_to_cache() {
    if ! manifest_matches_current_sha "$LOCAL_MANIFEST"; then
        return 0
    fi
    if ! installed_artifacts_present; then
        return 0
    fi
    # Never publish artifacts that disagree with their own manifest: the shared
    # cache is what every other worktree on this machine trusts.
    if ! installed_content_matches_manifest; then
        return 0
    fi

    local entry
    entry="$(cache_entry_dir)"
    if [[ -d "$entry" ]]; then
        # Keep a still-valid entry (idempotent), but replace one that fails the
        # validity check. The key covers every field that check compares, so a
        # mismatch here is a damaged or hand-edited entry rather than another
        # checkout's valid artifacts -- replacing it repairs the key instead of
        # taking it away from a peer that still wants it.
        #
        # The content digest is checked here for the same reason: an entry whose
        # artifacts no longer hash to what its manifest records is rejected by
        # every restore, so the run that rejected it downloads or builds good
        # artifacts and must repair the entry. Without this check the poisoned
        # entry would survive its own rejection and keep costing every reader a
        # wasted restore.
        local entry_manifest="$entry/ghostty-artifacts/manifest.json"
        if manifest_matches_current_sha "$entry_manifest"; then
            if cache_entry_content_matches_manifest "$entry"; then
                return 0
            fi
            echo "==> Replacing Ghostty cache entry whose artifacts do not match its recorded content digest ($entry)"
        else
            echo "==> Replacing stale Ghostty cache entry ($entry)"
        fi
        rm -rf "$entry"
    fi

    echo "==> Saving Ghostty artifacts to cache ($entry)"
    # This function runs with errexit disabled (it is called as `save_to_cache
    # || ...`), so the staging copies are checked explicitly. A partial copy
    # must never be published into the shared cache where later worktrees could
    # restore it past the minimal presence checks.
    mkdir -p "$GHOSTTY_CACHE_ROOT" || return 1
    local staging
    staging="$(mktemp -d "$GHOSTTY_CACHE_ROOT/.staging.XXXXXX")" || return 1

    if ! mkdir -p "$staging/ghosttyvt" \
        || ! cp -R "$GHOSTTYKIT_ROOT" "$staging/ghosttykit" \
        || ! cp -R "$GHOSTTYVT_INCLUDE_ROOT" "$staging/ghosttyvt/include" \
        || ! cp -R "$GHOSTTYVT_LIB_ROOT" "$staging/ghosttyvt/lib" \
        || ! cp -R "$ARTIFACT_STATE_ROOT" "$staging/ghostty-artifacts"; then
        rm -rf "$staging"
        return 1
    fi

    if ! mkdir -p "$(dirname "$entry")"; then
        rm -rf "$staging"
        return 1
    fi
    # Atomic publish: rename only when the destination is still absent so
    # concurrent worktree setups never observe a half-written entry. A
    # concurrent publisher winning the race counts as success; any other mv
    # failure (permissions, a corrupted cache path with a file where the entry
    # directory belongs) returns nonzero so the caller warns instead of
    # reporting a seeded cache that was never written.
    if [[ -d "$entry" ]]; then
        rm -rf "$staging"
        return 0
    fi
    if ! mv "$staging" "$entry" 2>/dev/null; then
        rm -rf "$staging"
        if [[ -d "$entry" ]]; then
            return 0
        fi
        return 1
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
    # Required: a manifest without the digest of the artifacts it describes cannot
    # be trusted by any reuse path, so there is no caller that may omit it.
    local content_digest="$4"
    local kit_checksum="${5:-}"
    local resources_checksum="${6:-}"
    local vt_checksum="${7:-}"

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
        "$(current_host_arch)" \
        "$GHOSTTY_BUILD_OPTIMIZE" \
        "$dirty" \
        "$mode" \
        "$content_digest" \
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
    content_digest,
    kit_checksum,
    resources_checksum,
    vt_checksum,
) = sys.argv[1:18]

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
    "artifact_content_digest": content_digest,
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

    require_metal_toolchain

    local zig_bin
    zig_bin="$(ensure_zig)"
    local app_version
    app_version="$(ghostty_app_version)"

    echo "==> Building Ghostty artifacts from $GHOSTTY_SOURCE_ROOT ($GHOSTTY_SHA, optimize=$GHOSTTY_BUILD_OPTIMIZE)"
    (
        cd "$GHOSTTY_SOURCE_ROOT"
        # Ghostty's vendored translate_c build helper shells out to a bare
        # `zig env`, so the pinned toolchain must be first on PATH.
        export PATH="$(dirname "$zig_bin"):$PATH"
        # -Dsentry=false: sentry-native's init thread reads a (ptr, len) snapshot of
        # environ while ghostty_init's locale setup calls setenv("LANG", ...) on this
        # thread, reallocating and freeing that array — a use-after-free that segfaults
        # spacesd and the iOS app. Spaces configures no DSN and never reads the local
        # envelopes sentry writes, so disable it rather than race it. The lib-vt build
        # below never reaches Ghostty's SharedDeps sentry block, so libghostty-vt has no
        # sentry symbols regardless and needs no flag.
        "$zig_bin" build -Doptimize="$GHOSTTY_BUILD_OPTIMIZE" -Demit-xcframework=true -Demit-macos-app=false -Di18n=false -Dsentry=false -Dversion-string="$app_version"
        "$zig_bin" build -Doptimize="$GHOSTTY_BUILD_OPTIMIZE" -Demit-lib-vt=true -Dversion-string="$app_version"
    )

    install_source_build_outputs
    installed_artifacts_present || die "Ghostty source build did not install a loadable libghostty-vt runtime library"
    normalize_ghosttykit_static_library
    # After normalization, so the recorded digest describes the tree every reuse
    # path re-hashes (normalization rewrites the static library name and the
    # xcframework Info.plist).
    compute_installed_content_digest || die "failed to digest the Ghostty artifacts installed by the source build"
    write_manifest "$LOCAL_MANIFEST" "$dirty" "build" "$INSTALLED_CONTENT_DIGEST"
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
        "$VALIDATION_XCODE_BUILD_MISMATCH" \
        "$GHOSTTY_BUILD_OPTIMIZE" \
        "$VALIDATION_OPTIMIZE_MISMATCH" \
        "$(current_host_arch)" \
        "$VALIDATION_HOST_ARCH_MISMATCH" <<'PY'
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
expected_optimize = sys.argv[10]
optimize_mismatch_status = int(sys.argv[11])
expected_host_arch = sys.argv[12]
host_arch_mismatch_status = int(sys.argv[13])
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

optimize_mismatch = False
if manifest.get("build_optimize") != expected_optimize:
    print(
        f"Ghostty artifact manifest build-optimize mode {manifest.get('build_optimize')} does not match requested mode "
        f"{expected_optimize}; rebuild locally with --build for that mode or unset SPACES_GHOSTTY_BUILD_OPTIMIZE to use the released mode.",
        file=sys.stderr,
    )
    optimize_mismatch = True

host_arch_mismatch = False
if manifest.get("host_arch") != expected_host_arch:
    print(
        f"Ghostty artifact manifest host architecture {manifest.get('host_arch')} does not match current host "
        f"architecture {expected_host_arch}; rebuild locally with --build or publish artifacts built on this architecture.",
        file=sys.stderr,
    )
    host_arch_mismatch = True

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
if optimize_mismatch:
    sys.exit(optimize_mismatch_status)
if host_arch_mismatch:
    sys.exit(host_arch_mismatch_status)
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

    if [[ "$MODE" == "default" ]] \
        && { [[ "$validation_status" -eq "$VALIDATION_XCODE_BUILD_MISMATCH" ]] \
            || [[ "$validation_status" -eq "$VALIDATION_OPTIMIZE_MISMATCH" ]] \
            || [[ "$validation_status" -eq "$VALIDATION_HOST_ARCH_MISMATCH" ]]; }; then
        rm -rf "$tmp_dir"
        trap - EXIT
        if [[ "$validation_status" -eq "$VALIDATION_OPTIMIZE_MISMATCH" ]]; then
            echo "==> Downloaded Ghostty artifacts use a different build-optimize mode; building locally instead"
        elif [[ "$validation_status" -eq "$VALIDATION_HOST_ARCH_MISMATCH" ]]; then
            echo "==> Downloaded Ghostty artifacts were built for a different host architecture; building locally instead"
        else
            echo "==> Downloaded Ghostty artifacts were built with a different Xcode build; building locally instead"
        fi
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

    installed_artifacts_present || die "Downloaded Ghostty artifacts did not install a loadable libghostty-vt runtime library"
    normalize_ghosttykit_static_library
    # The asset checksums above prove the tarballs are the ones the manifest was
    # written for; this proves the tree they unpacked to is. A release whose
    # manifest describes different content than it ships is broken at the source
    # and cannot be repaired here, so it fails loudly. The rejected artifacts stay
    # where they were unpacked, which is harmless: they carry the manifest they
    # failed against, so the next setup rejects them on the same digest instead of
    # reusing them.
    installed_content_matches_manifest \
        || die "Downloaded Ghostty artifacts do not match the content digest in their manifest; republish $release_tag with apps/macos/scripts/ensure_ghostty_artifacts.sh on a trusted workflow or build locally with --build"
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
    # The packaged manifest carries the digest of the installed trees the tarballs
    # were made from, which is what a consumer recomputes after extracting them.
    # The build that produced this install already computed it.
    compute_installed_content_digest || die "failed to digest the Ghostty artifacts being packaged"
    write_manifest "$package_dir/manifest.json" "$dirty" "build" "$INSTALLED_CONTENT_DIGEST" \
        "$kit_checksum" "$resources_checksum" "$vt_checksum"

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

# Shared, content-addressed artifact cache, rooted in the primary checkout so a
# worktree restores a SHA the primary checkout already built with a local copy
# instead of redownloading or rebuilding its own multi-gigabyte copy. Resolved
# here rather than by each caller: when callers derived it, any entry point that
# forgot to (scripts/verify.sh, through verify-prep.sh) silently seeded a private
# per-worktree store. SPACES_GHOSTTY_CACHE_DIR relocates the cache for the
# hermetic setup tests, which run against fixture checkouts.
if [[ -n "${SPACES_GHOSTTY_CACHE_DIR:-}" ]]; then
    GHOSTTY_CACHE_ROOT="$SPACES_GHOSTTY_CACHE_DIR"
else
    GHOSTTY_CACHE_ROOT="$(primary_checkout_dir)/apps/macos/.local/ghostty-cache"
fi

case "$MODE" in
    default)
        if ! reuse_local_artifacts_if_valid; then
            if ! restore_from_cache_if_valid; then
                download_release_artifacts
            fi
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

# Seed the shared cache from the installed artifacts. Runs after every mode
# (including the fast local-reuse path) so the main checkout populates the cache
# for worktrees without a separate step. A failure here must not fail an
# otherwise-complete setup.
save_to_cache || echo "==> Warning: could not populate Ghostty artifact cache (continuing)"

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
