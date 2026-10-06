#!/usr/bin/env bash
# Usage: apps/macos/scripts/smoke_linux_spacesd_artifact_on_distros.sh --arch x86_64|arm64
#
# Runs smoke_linux_spacesd_artifact.sh on dist/linux/spacesd-linux-<arch>.tar.gz inside a fresh
# container of every supported distribution, so the published archive is proven on each of them and
# not only on the swift:6.2-noble image that builds it. Needs a Docker host (a CI runner, or a Mac
# with Docker Desktop) and an archive from build_linux_spacesd_artifact.sh. Every image runs even
# when an earlier one fails; the exit status is non-zero if any failed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# The single source of truth for the tested distributions. README.md, docs/spec.md, and the web
# docs name this same list; change them together.
IMAGES=(
    ubuntu:24.04
    ubuntu:26.04
    debian:13
    fedora:43
    almalinux:10
)

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
        *)
            die "unknown smoke_linux_spacesd_artifact_on_distros.sh argument: $1"
            ;;
    esac
done

case "$arch" in
    x86_64) docker_platform="linux/amd64" ;;
    arm64) docker_platform="linux/arm64" ;;
    *) die "--arch is required and must be x86_64 or arm64" ;;
esac

archive_name="spacesd-linux-$arch.tar.gz"
[[ -f "$REPO_ROOT/dist/linux/$archive_name" ]] || die "artifact archive missing at $REPO_ROOT/dist/linux/$archive_name"

# Runs inside the container as root. Only what the smoke and the bundled install.sh call that a
# slim image can lack is installed:
#   python3          the smoke's pairing, PTY, and database checks
#   openssl          the pinned-TLS pairing round trip (absent from the Fedora and AlmaLinux images)
#   ca-certificates  TLS roots on Debian-family images
#   tar, gzip        unpacking the archive
#   findutils        find and xargs, which the checksum and install steps use
#   gawk             awk, which install.sh uses to read the manifest version (Debian-family images
#                    already ship an awk)
# coreutils (id, stat, readlink, mktemp, timeout, sha256sum), grep, sed, bash, and ldd (glibc) come
# with every image listed above.
container_script='
set -euo pipefail
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends python3 openssl ca-certificates >/dev/null
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q python3 openssl tar gzip findutils gawk >/dev/null
else
    echo "no supported package manager (apt-get or dnf) in this image" >&2
    exit 1
fi
exec /repo/apps/macos/scripts/smoke_linux_spacesd_artifact.sh "/repo/dist/linux/'"$archive_name"'"
'

failed=()
for image in "${IMAGES[@]}"; do
    echo "==> $image ($docker_platform)"
    # The `if` only captures this image's result; `set -e` stays on inside the container command.
    if docker run --rm --platform "$docker_platform" -v "$REPO_ROOT":/repo:ro "$image" bash -c "$container_script"; then
        echo "PASS $image"
    else
        echo "FAIL $image"
        failed+=("$image")
    fi
done

echo
echo "==> Summary for $archive_name"
for image in "${IMAGES[@]}"; do
    status="PASS"
    for failed_image in ${failed[@]+"${failed[@]}"}; do
        [[ "$failed_image" == "$image" ]] && status="FAIL"
    done
    echo "$status $image"
done

[[ "${#failed[@]}" -eq 0 ]]
