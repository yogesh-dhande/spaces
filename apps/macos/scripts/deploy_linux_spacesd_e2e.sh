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
artifact_cache_root="$linux_cache_root/artifacts"

spaces_e2e_require_remote_host_env "$repo_root"

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

cache_file_digest() {
  local label="$1"
  local path="$2"
  [[ -f "$path" ]] || return 0
  local digest
  digest="$(shasum -a 256 "$path" | awk '{print $1}')"
  printf 'file\t%s\t%s\n' "$label" "$digest"
}

source_cache_key() {
  local path ghostty_root repo_status_sha ghostty_status_text ghostty_status_sha
  ghostty_root="$repo_root/apps/macos/vendor/ghostty"
  repo_status_sha="$(
    git -C "$repo_root" status --porcelain=v1 -z --untracked-files=all -- \
      apps/macos/Package.swift \
      apps/macos/Package.resolved \
      apps/macos/Sources \
      apps/macos/scripts/build_linux_spacesd_artifact.sh \
      | shasum -a 256 | awk '{print $1}'
  )"

  {
    printf 'schema=1\n'
    printf 'artifact_id=%s\n' "$artifact_id"
    printf 'arch=%s\n' "$arch"
    printf 'repo_status_sha256=%s\n' "$repo_status_sha"
    while IFS= read -r -d '' path; do
      cache_file_digest "$path" "$repo_root/$path"
    done < <(
      git -C "$repo_root" ls-files -z --cached --others --exclude-standard -- \
        apps/macos/Package.swift \
        apps/macos/Package.resolved \
        apps/macos/Sources \
        apps/macos/scripts/build_linux_spacesd_artifact.sh
    )

    if git -C "$ghostty_root" rev-parse --git-dir >/dev/null 2>&1; then
      printf 'ghostty_head=%s\n' "$(git -C "$ghostty_root" rev-parse HEAD)"
      ghostty_status_text="$(git -C "$ghostty_root" status --porcelain=v1 --untracked-files=all)"
      if [[ -n "$ghostty_status_text" && "${SPACES_LINUX_ALLOW_DIRTY_GHOSTTY:-0}" != "1" ]]; then
        echo "Ghostty submodule has local modifications; commit them before building Linux spacesd artifacts" >&2
        exit 1
      fi
      ghostty_status_sha="$(
        git -C "$ghostty_root" status --porcelain=v1 -z --untracked-files=all \
          | shasum -a 256 | awk '{print $1}'
      )"
      printf 'ghostty_status_sha256=%s\n' "$ghostty_status_sha"
      if [[ -n "$ghostty_status_text" ]]; then
        while IFS= read -r -d '' path; do
          cache_file_digest "apps/macos/vendor/ghostty/$path" "$ghostty_root/$path"
        done < <(git -C "$ghostty_root" ls-files -z --cached --others --exclude-standard)
      fi
    else
      git -C "$repo_root" ls-files -s -- apps/macos/vendor/ghostty
    fi
  } | shasum -a 256 | awk '{print $1}'
}

valid_cached_archive() {
  local archive="$1"
  local checksum_file="$2"
  [[ -f "$archive" && -f "$checksum_file" ]] || return 1
  local expected actual
  expected="$(awk '{print $1; exit}' "$checksum_file")"
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [[ -n "$expected" && "$expected" == "$actual" ]]
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
cache_key="$(source_cache_key)"
cached_archive_path="$artifact_cache_root/$artifact_id-$cache_key.tar.gz"
cached_archive_sha256_path="$cached_archive_path.sha256"
remote_upload_dir=".spaces/remote-artifact-e2e"
remote_home="$(ssh "${ssh_args[@]}" "$ssh_destination" 'printf "%s" "$HOME"')"
remote_archive_dir="$remote_home/$remote_upload_dir"
remote_archive_path="$remote_archive_dir/$archive_name"

mkdir -p "$(dirname "$archive_path")" "$artifact_cache_root"
if valid_cached_archive "$cached_archive_path" "$cached_archive_sha256_path"; then
  echo "==> Reusing cached $artifact_id archive for source key $cache_key" >&2
  cp "$cached_archive_path" "$archive_path"
  cp "$cached_archive_sha256_path" "$archive_path.sha256"
else
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
  cp "$archive_path" "$cached_archive_path"
  cp "$archive_path.sha256" "$cached_archive_sha256_path"
fi

if [[ ! -f "$archive_path" ]]; then
  echo "Linux spacesd artifact was not produced at $archive_path" >&2
  exit 1
fi

archive_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"

echo "==> Preparing remote artifact directory on $ssh_destination" >&2
ssh "${ssh_args[@]}" "$ssh_destination" "mkdir -p '$remote_archive_dir'"

remote_archive_sha256="$(
  ssh "${ssh_args[@]}" "$ssh_destination" "cat '$remote_archive_path.sha256' 2>/dev/null | awk '{print \$1}' || true"
)"
if [[ "$remote_archive_sha256" == "$archive_sha256" ]]; then
  echo "==> Reusing remote $archive_name with matching checksum" >&2
else
  echo "==> Uploading $archive_name" >&2
  scp "${scp_args[@]}" "$archive_path" "$ssh_destination:$remote_archive_path" >/dev/null
  ssh "${ssh_args[@]}" "$ssh_destination" "printf '%s  %s\n' '$archive_sha256' '$archive_name' > '$remote_archive_path.sha256'"
fi

printf 'artifact_id=%q\n' "$artifact_id"
printf 'artifact_url=%q\n' "file://$remote_archive_path"
printf 'artifact_sha256=%q\n' "$archive_sha256"
printf 'artifact_arch=%q\n' "$arch"
printf 'artifact_cache_key=%q\n' "$cache_key"

echo "==> Remote Linux E2E managed artifact ready" >&2
