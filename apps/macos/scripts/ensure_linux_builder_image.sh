#!/usr/bin/env bash
set -euo pipefail

# Builds (when missing) and names the Docker image every Linux spacesd artifact build runs in.
#
# The image carries the Swift toolchain base, the apt packages the artifact build needs, and the
# pinned Zig toolchain. Provisioning those inside a fresh container on every build cost an
# apt-get run and a Zig download per build, and put Zig on the bind mount so each worktree kept
# its own copy. Baking them means a build starts compiling immediately and every worktree on the
# machine shares one image.
#
# The tag is a digest of exactly what goes into the image (base image ref, package list, Zig
# version, and the Dockerfile below), so changing any of them names a different image and the
# next build provisions it. Nothing invalidates the image when the *base tag* is republished
# upstream; `docker rmi` the tag to pick that up.
#
# Prints the image tag on stdout; build progress goes to stderr so callers can capture the tag.

script_dir="$(cd "$(dirname "$0")" && pwd)"
source "$script_dir/linux-builder-versions.sh"

die() {
    echo "$*" >&2
    exit 1
}

arch=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --arch)
            [[ "$#" -ge 2 ]] || die "--arch requires x86_64 or arm64"
            arch="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: ensure_linux_builder_image.sh --arch x86_64|arm64"
            exit 0
            ;;
        *)
            die "unknown ensure_linux_builder_image.sh argument: $1"
            ;;
    esac
done

case "$arch" in
    x86_64) docker_platform="linux/amd64" ;;
    arm64) docker_platform="linux/arm64" ;;
    *) die "ensure_linux_builder_image.sh requires --arch x86_64 or --arch arm64" ;;
esac

# Zig is unpacked into a versioned root and reached through /usr/local/bin, which is on the
# default PATH of a login shell as well as a plain exec. Zig resolves its own lib/ directory
# from /proc/self/exe, so the symlink does not hide the toolchain from it.
read -r -d '' dockerfile <<EOF || true
FROM $SPACES_LINUX_BUILDER_BASE_IMAGE
RUN apt-get update && apt-get install -y $SPACES_LINUX_BUILDER_APT_PACKAGES && rm -rf /var/lib/apt/lists/*
RUN set -eux; \\
    case "\$(uname -m)" in \\
        x86_64) zig_arch=x86_64 ;; \\
        aarch64|arm64) zig_arch=aarch64 ;; \\
        *) echo "unsupported builder architecture: \$(uname -m)" >&2; exit 1 ;; \\
    esac; \\
    archive="zig-\${zig_arch}-linux-$SPACES_LINUX_ZIG_VERSION.tar.xz"; \\
    curl -fL "https://ziglang.org/download/$SPACES_LINUX_ZIG_VERSION/\$archive" -o /tmp/\$archive; \\
    mkdir -p /opt/zig-$SPACES_LINUX_ZIG_VERSION; \\
    tar -xJf /tmp/\$archive -C /opt/zig-$SPACES_LINUX_ZIG_VERSION --strip-components=1; \\
    rm /tmp/\$archive; \\
    ln -s /opt/zig-$SPACES_LINUX_ZIG_VERSION/zig /usr/local/bin/zig; \\
    zig version
EOF

image_digest="$(
    python3 - "$dockerfile" <<'PY'
import hashlib
import sys

print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest()[:12])
PY
)"
image_tag="spaces-linux-builder:$arch-$image_digest"

if docker image inspect "$image_tag" >/dev/null 2>&1; then
    printf '%s\n' "$image_tag"
    exit 0
fi

echo "==> Building Linux builder image $image_tag" >&2
printf '%s\n' "$dockerfile" | docker build --platform "$docker_platform" -t "$image_tag" - >&2

printf '%s\n' "$image_tag"
