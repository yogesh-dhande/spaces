#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
app_root="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$app_root/../.." && pwd)"
source "$repo_root/scripts/spaces-e2e-env.sh"

artifact_id="spacesd-ubuntu-24.04-x86_64"
archive_name="$artifact_id.tar.gz"
archive_path="$repo_root/dist/linux/$archive_name"
remote_install_root=".spaces/e2e-tools"
remote_upload_dir="$remote_install_root/.uploads"
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

echo "==> Building $artifact_id with Swift 6.2 Noble Docker"
mkdir -p "$zig_cache_root" "$swiftpm_cache_root"
docker_args=(run --rm --platform linux/amd64)
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
    apps/macos/scripts/build_linux_spacesd_artifact.sh
  '

if [[ ! -f "$archive_path" ]]; then
  echo "Linux spacesd artifact was not produced at $archive_path" >&2
  exit 1
fi

echo "==> Preparing remote upload directory on $ssh_destination"
ssh "${ssh_args[@]}" "$ssh_destination" "mkdir -p '$remote_upload_dir'"

echo "==> Uploading $archive_name"
scp "${scp_args[@]}" "$archive_path" "$ssh_destination:$remote_upload_dir/$archive_name"
if [[ -f "$archive_path.sha256" ]]; then
  scp "${scp_args[@]}" "$archive_path.sha256" "$ssh_destination:$remote_upload_dir/$archive_name.sha256"
fi

echo "==> Installing $artifact_id under ~/$remote_install_root"
ssh "${ssh_args[@]}" "$ssh_destination" "ARTIFACT_ID='$artifact_id' ARCHIVE_NAME='$archive_name' INSTALL_ROOT='$remote_install_root' bash -s" <<'REMOTE_INSTALL'
set -euo pipefail

install_root="$HOME/$INSTALL_ROOT"
upload_dir="$install_root/.uploads"
archive_path="$upload_dir/$ARCHIVE_NAME"
extract_root="$(mktemp -d "$install_root/.extract.XXXXXX")"
backup_root="$install_root/$ARTIFACT_ID.previous"

cleanup() {
  rm -rf "$extract_root"
}
trap cleanup EXIT

tar -xzf "$archive_path" -C "$extract_root"
test -x "$extract_root/$ARTIFACT_ID/bin/spacesd"
test -x "$extract_root/$ARTIFACT_ID/bin/spaces"
test -x "$extract_root/$ARTIFACT_ID/bin/spacesd-bin"

(
  cd "$extract_root/$ARTIFACT_ID"
  sha256sum -c SHA256SUMS >/dev/null
)

rm -rf "$backup_root"
if [ -e "$install_root/$ARTIFACT_ID" ]; then
  mv "$install_root/$ARTIFACT_ID" "$backup_root"
fi
mv "$extract_root/$ARTIFACT_ID" "$install_root/$ARTIFACT_ID"

mkdir -p "$HOME/bin"
ln -sfn "$install_root/$ARTIFACT_ID/bin/spacesd" "$HOME/bin/spacesd"
ln -sfn "$install_root/$ARTIFACT_ID/bin/spaces" "$HOME/bin/spaces"

fingerprint="$(SPACES_DB_PATH="$install_root/.deploy-smoke/spaces.db" \
  SPACES_RUNTIME_DIR="$install_root/.deploy-smoke/runtime" \
  SPACESD_PRINT_CERTIFICATE_FINGERPRINT=1 "$HOME/bin/spacesd")"
case "$fingerprint" in
  SHA256:*) ;;
  *)
    echo "Installed spacesd did not print a certificate fingerprint." >&2
    exit 1
    ;;
esac

echo "installed=$install_root/$ARTIFACT_ID"
echo "spacesd=$HOME/bin/spacesd"
echo "fingerprint=$fingerprint"
REMOTE_INSTALL

echo "==> Remote Linux spacesd deploy complete"
