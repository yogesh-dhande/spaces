#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
app_root="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$app_root/../.." && pwd)"
source "$repo_root/scripts/spaces-e2e-env.sh"

git_common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)"
linux_cache_root="$app_root/.build/linux-e2e-cache"
zig_cache_root="$linux_cache_root/zig"
swiftpm_cache_root="$linux_cache_root/swiftpm"

spaces_e2e_load_env "$repo_root"

remote_host="${SPACES_E2E_REMOTE_SSH_HOST:-}"
remote_user="${SPACES_E2E_REMOTE_SSH_USER:-}"
remote_port="${SPACES_E2E_REMOTE_SSH_PORT:-}"

if [[ -z "$remote_host" ]]; then
  echo "SPACES_E2E_REMOTE_SSH_HOST is required." >&2
  exit 1
fi

ssh_destination="$remote_host"
if [[ -n "$remote_user" ]]; then
  ssh_destination="$remote_user@$remote_host"
fi

ssh_args=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes)
scp_args=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes)
if [[ -n "$remote_port" ]]; then
  ssh_args+=(-p "$remote_port")
  scp_args+=(-P "$remote_port")
fi

normalize_arch() {
  case "$1" in
    amd64|x64) printf 'x86_64\n' ;;
    aarch64) printf 'arm64\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

probe_output="$(
  ssh "${ssh_args[@]}" "$ssh_destination" 'set -eu
    printf "os=%s\n" "$(uname -s)"
    printf "arch=%s\n" "$(uname -m)"
    if [ "$(uname -s)" = "Linux" ] && [ -r /etc/os-release ]; then
      . /etc/os-release
      printf "linux_id=%s\n" "${ID:-}"
      printf "linux_version_id=%s\n" "${VERSION_ID:-}"
    fi'
)"

os_name=""
arch_raw=""
linux_id=""
linux_version_id=""
while IFS='=' read -r key value; do
  case "$key" in
    os) os_name="$value" ;;
    arch) arch_raw="$value" ;;
    linux_id) linux_id="$value" ;;
    linux_version_id) linux_version_id="$value" ;;
  esac
done <<<"$probe_output"

if [[ "$os_name" != "Linux" ]]; then
  echo "Remote E2E artifact helper only supports Linux remotes. Found $os_name." >&2
  exit 1
fi
if [[ "$linux_id" != "ubuntu" || "$linux_version_id" != "24.04" ]]; then
  echo "Remote E2E artifact helper requires Ubuntu 24.04. Found id=$linux_id version=$linux_version_id." >&2
  exit 1
fi

arch="$(normalize_arch "$arch_raw")"
case "$arch" in
  x86_64)
    artifact_id="spacesd-ubuntu-24.04-x86_64"
    docker_platform="linux/amd64"
    ;;
  arm64)
    artifact_id="spacesd-ubuntu-24.04-arm64"
    docker_platform="linux/arm64"
    ;;
  *)
    echo "Unsupported remote Linux architecture: $arch_raw" >&2
    exit 1
    ;;
esac

archive_name="$artifact_id.tar.gz"
archive_path="$repo_root/dist/linux/$archive_name"
remote_upload_dir=".spaces/remote-artifact-e2e"
remote_home="$(ssh "${ssh_args[@]}" "$ssh_destination" 'printf "%s" "$HOME"')"
remote_archive_dir="$remote_home/$remote_upload_dir"
remote_archive_path="$remote_archive_dir/$archive_name"

echo "==> Building $artifact_id with Swift 6.2 Noble Docker" >&2
mkdir -p "$zig_cache_root" "$swiftpm_cache_root"
docker_args=(run --rm --platform "$docker_platform")
if [[ "$git_common_dir" != "$repo_root/.git" ]]; then
  docker_args+=(-v "$git_common_dir:$git_common_dir")
fi
docker "${docker_args[@]}" \
  -v "$repo_root:/workspace" \
  -v "$zig_cache_root:/root/.cache/zig" \
  -v "$swiftpm_cache_root:/root/.cache/org.swift.swiftpm" \
  -w /workspace \
  swift:6.2-noble \
  bash -lc '
    set -euo pipefail
    apt-get update
    apt-get install -y curl git xz-utils python3 pkg-config libsqlite3-dev libssl-dev openssl coreutils
    git config --global --add safe.directory /workspace
    git config --global --add safe.directory /workspace/apps/macos/vendor/ghostty
    apps/macos/scripts/build_linux_spacesd_artifact.sh --arch '"$arch"'
  ' >&2

if [[ ! -f "$archive_path" ]]; then
  echo "Linux spacesd artifact was not produced at $archive_path" >&2
  exit 1
fi

archive_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"

echo "==> Preparing remote artifact directory on $ssh_destination" >&2
ssh "${ssh_args[@]}" "$ssh_destination" "mkdir -p '$remote_archive_dir'"

echo "==> Uploading $archive_name" >&2
scp "${scp_args[@]}" "$archive_path" "$ssh_destination:$remote_archive_path" >/dev/null

printf 'artifact_id=%q\n' "$artifact_id"
printf 'artifact_url=%q\n' "file://$remote_archive_path"
printf 'artifact_sha256=%q\n' "$archive_sha256"
printf 'artifact_arch=%q\n' "$arch"

echo "==> Remote Linux E2E managed artifact ready" >&2
