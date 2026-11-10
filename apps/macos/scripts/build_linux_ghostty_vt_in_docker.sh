#!/usr/bin/env bash
set -euo pipefail

# Host-side entry for the libghostty-vt build: runs build_linux_ghostty_vt.sh in the builder
# container of the Docker engine's own architecture, whatever artifact architecture it builds
# for. Zig 0.17's x86_64 Linux binary traps under Rosetta, so on Apple Silicon the x86_64
# artifact's library is cross-compiled by the arm64 container; on an x86_64 host (CI) the same
# call is a same-architecture build. Run it before the artifact build container.
#
# The Zig cache lives in a named Docker volume, never the bind-mounted workspace: POSIX locking
# over Docker Desktop's macOS file sharing deadlocks `zig build`.

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"

die() {
    echo "$*" >&2
    exit 1
}

arch=""
zig_cache_volume=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --arch)
            [[ "$#" -ge 2 ]] || die "--arch requires x86_64 or arm64"
            arch="$2"
            shift 2
            ;;
        --zig-cache-volume)
            [[ "$#" -ge 2 ]] || die "--zig-cache-volume requires a Docker volume name"
            zig_cache_volume="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: build_linux_ghostty_vt_in_docker.sh --arch x86_64|arm64 --zig-cache-volume NAME"
            exit 0
            ;;
        *)
            die "unknown build_linux_ghostty_vt_in_docker.sh argument: $1"
            ;;
    esac
done
[[ -n "$arch" ]] || die "build_linux_ghostty_vt_in_docker.sh requires --arch"
[[ -n "$zig_cache_volume" ]] || die "build_linux_ghostty_vt_in_docker.sh requires --zig-cache-volume"

engine_arch="$(docker info --format '{{.Architecture}}')"
case "$engine_arch" in
    x86_64|amd64) native_arch="x86_64"; native_platform="linux/amd64" ;;
    aarch64|arm64) native_arch="arm64"; native_platform="linux/arm64" ;;
    *) die "unsupported Docker engine architecture: $engine_arch" ;;
esac

builder_image="$("$script_dir/ensure_linux_builder_image.sh" --arch "$native_arch")"
echo "==> Building libghostty-vt for $arch with $builder_image ($native_arch container)" >&2

docker_args=(run --rm --init --platform "$native_platform")
# A worktree's .git is a pointer into the common git dir, which the submodule checks need.
git_common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)"
if [[ "$git_common_dir" != "$repo_root/.git" ]]; then
    docker_args+=(-v "$git_common_dir:$git_common_dir")
fi
docker "${docker_args[@]}" \
    -v "$repo_root:/workspace" \
    -v "$zig_cache_volume:/root/spaces-zig-cache" \
    -e ZIG_LOCAL_CACHE_DIR=/root/spaces-zig-cache/local \
    -e ZIG_GLOBAL_CACHE_DIR=/root/spaces-zig-cache/global \
    -e SPACES_LINUX_ALLOW_DIRTY_GHOSTTY="${SPACES_LINUX_ALLOW_DIRTY_GHOSTTY:-0}" \
    -w /workspace \
    "$builder_image" \
    bash -lc '
        set -euo pipefail
        git config --global --add safe.directory /workspace
        git config --global --add safe.directory /workspace/apps/macos/vendor/ghostty
        apps/macos/scripts/build_linux_ghostty_vt.sh --arch '"$arch"'
    '
