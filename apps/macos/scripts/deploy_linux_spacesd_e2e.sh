#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
app_root="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$app_root/../.." && pwd)"
source "$repo_root/scripts/spaces-e2e-env.sh"

# The profile this deploy targets. It keys the remote staging directory, so two deploys aimed at
# different profiles of the same account never share the uploaded archive or the tree it is
# extracted into -- each cleans and fills only its own.
profile_name=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ "$#" -ge 2 ]] || { echo "--profile requires a profile name." >&2; exit 1; }
      profile_name="$2"
      shift 2
      ;;
    *)
      echo "unknown deploy_linux_spacesd_e2e.sh argument: $1" >&2
      exit 1
      ;;
  esac
done
if [[ -z "$profile_name" ]]; then
  echo "deploy_linux_spacesd_e2e.sh requires --profile NAME naming the profile this deploy installs into." >&2
  exit 1
fi
# The installer's own validation, applied before the name reaches any remote path or SSH command.
# The name becomes a path component under the staging root and is interpolated into remote shell
# commands that clean that tree, so a traversal name ('.', '..') or one outside the literal-safe
# charset must never leave this machine. Matched under the C locale: bracket ranges follow the
# caller's locale, and under UTF-8 collation 'A-Za-z' also matches accented letters — exactly the
# names (from non-ASCII branch slugs) this check exists to stop.
if ! LC_ALL=C bash -c 'case "$1" in . | .. | *[!A-Za-z0-9._-]*) exit 1 ;; esac' -- "$profile_name"; then
  echo "deploy_linux_spacesd_e2e.sh --profile '$profile_name' is not a valid profile name: letters, digits, '.', '_', and '-' only, and not '.' or '..'." >&2
  exit 1
fi

git_common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)"
linux_cache_root="$app_root/.build/linux-e2e-cache"
artifact_cache_root="$linux_cache_root/artifacts"

# The zig and SwiftPM mutable build/cache state lives in named Docker volumes rather
# than host bind mounts (see the docker invocation below for why). Name them per
# worktree from a short stable hash of the repo root so concurrent worktrees keep
# isolated build state; the hash keeps the names within Docker's [a-zA-Z0-9_.-] rule.
repo_hash="$(printf '%s' "$repo_root" | shasum -a 256 | awk '{print substr($1, 1, 8)}')"
zig_cache_volume="spaces-linux-zig-$repo_hash"
swift_cache_volume="spaces-linux-swift-$repo_hash"

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

ghostty_submodule_is_initialized() {
  local ghostty_root="$1"
  [[ -e "$ghostty_root/.git" ]] || return 1
  git -C "$ghostty_root" rev-parse --git-dir >/dev/null 2>&1
}

# Every path whose content can change the artifact this build produces.
#
# The Linux build compiles only the `spacesd` and `spaces` products, so a target outside their
# dependency closure cannot reach the archive. Hashing all of apps/macos/Sources turned every
# macOS-only change -- the most common kind a development launch carries -- into a miss whose
# rebuild produced a byte-identical artifact.
#
# The closure is derived from Package.swift at key time rather than listed here, so adding a
# target or rewiring a dependency needs no edit. Only directories the manifest declares as
# targets *outside* the closure are dropped; every other entry under Sources is kept, which
# covers the Linux-only targets the macOS manifest does not declare at all (CSQLite3, OpenSSL)
# and anything that is not a target. A path kept needlessly costs at most a rebuild, while a
# path dropped wrongly would ship a stale artifact.
linux_build_source_paths() {
  # Compiling Package.swift to answer `dump-package` resolves clang module and SwiftPM
  # cache/config/security paths to default user-level locations, which can be missing or
  # read-only in a sandboxed checkout — the same isolation impacted_tests.sh applies to
  # `describe`. `--disable-sandbox` because manifest evaluation otherwise runs under
  # sandbox-exec, which an already-sandboxed caller cannot nest (`sandbox_apply: Operation
  # not permitted`); the query is read-only over this repository's own manifest. The
  # top-level options must precede the subcommand to be recognized.
  local spm_cache_root="$app_root/.build"
  mkdir -p "$spm_cache_root/spm-cache" "$spm_cache_root/spm-config" "$spm_cache_root/spm-security" "$spm_cache_root/clang-module-cache"
  local manifest_json
  manifest_json="$(
    CLANG_MODULE_CACHE_PATH="$spm_cache_root/clang-module-cache" \
      xcrun swift package --package-path "$app_root" \
      --disable-sandbox \
      --cache-path "$spm_cache_root/spm-cache" \
      --config-path "$spm_cache_root/spm-config" \
      --security-path "$spm_cache_root/spm-security" \
      dump-package
  )"
  python3 - "$repo_root" "$app_root" "$manifest_json" <<'PY'
import json
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
app_root = Path(sys.argv[2])
manifest = json.loads(sys.argv[3])
targets = {target["name"]: target for target in manifest["targets"]}


def dependency_names(target):
    for dependency in target["dependencies"]:
        for kind, value in dependency.items():
            if kind in ("byName", "target"):
                yield value[0]


closure = set()
pending = []
for product in manifest["products"]:
    if product["name"] in ("spacesd", "spaces"):
        pending.extend(product["targets"])
while pending:
    name = pending.pop()
    if name in closure or name not in targets:
        continue
    closure.add(name)
    pending.extend(dependency_names(targets[name]))
if not closure:
    raise SystemExit("Package.swift declares no spacesd/spaces products; cannot derive the Linux build closure")

sources_root = (app_root / "Sources").resolve()
excluded = set()
for name, target in targets.items():
    if name in closure:
        continue
    directory = (app_root / (target.get("path") or f"Sources/{name}")).resolve()
    if directory.parent == sources_root:
        excluded.add(directory)

for entry in sorted(sources_root.iterdir()):
    if entry.resolve() not in excluded:
        print(entry.resolve().relative_to(repo_root))
PY
}

source_cache_key() {
  local path ghostty_root repo_status_sha ghostty_status_text ghostty_status_sha
  ghostty_root="$repo_root/apps/macos/vendor/ghostty"
  repo_status_sha="$(
    git -C "$repo_root" status --porcelain=v1 -z --untracked-files=all -- "${key_paths[@]}" \
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
      git -C "$repo_root" ls-files -z --cached --others --exclude-standard -- "${key_paths[@]}"
    )

    if ghostty_submodule_is_initialized "$ghostty_root"; then
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

# The manifest, the resolved dependency versions, the build script, and the builder image
# definition all change the artifact just as source does, so they are keyed alongside the
# closure's source directories.
key_paths=(
  apps/macos/Package.swift
  apps/macos/Package.resolved
  apps/macos/scripts/build_linux_spacesd_artifact.sh
  apps/macos/scripts/ensure_linux_builder_image.sh
  apps/macos/scripts/linux-builder-versions.sh
)
linux_source_paths_text="$(linux_build_source_paths)"
[[ -n "$linux_source_paths_text" ]] || {
  echo "Could not derive the Linux build's source directories from apps/macos/Package.swift" >&2
  exit 1
}
while IFS= read -r source_path; do
  key_paths+=("$source_path")
done <<<"$linux_source_paths_text"

cache_key="$(source_cache_key)"
cached_archive_path="$artifact_cache_root/$artifact_id-$cache_key.tar.gz"
cached_archive_sha256_path="$cached_archive_path.sha256"
remote_upload_dir=".spaces/remote-artifact-e2e/$profile_name"
remote_home="$(ssh "${ssh_args[@]}" "$ssh_destination" 'printf "%s" "$HOME"')"
remote_archive_dir="$remote_home/$remote_upload_dir"
remote_archive_path="$remote_archive_dir/$archive_name"

mkdir -p "$(dirname "$archive_path")" "$artifact_cache_root"
if valid_cached_archive "$cached_archive_path" "$cached_archive_sha256_path"; then
  echo "==> Reusing cached $artifact_id archive for source key $cache_key" >&2
  cp "$cached_archive_path" "$archive_path"
  cp "$cached_archive_sha256_path" "$archive_path.sha256"
else
  # The builder image carries the Swift toolchain, the build's apt packages, and the pinned zig,
  # so the container starts compiling instead of provisioning itself. It is built once per
  # machine and reused by every worktree.
  builder_image="$("$script_dir/ensure_linux_builder_image.sh" --arch "$arch")"
  echo "==> Building $artifact_id with $builder_image" >&2
  # Keep zig and SwiftPM cache/build state in named Docker volumes, not host bind mounts:
  # lock acquisition over Docker Desktop's macOS file sharing deadlocks the ghostty-vt
  # `zig build`. Volumes live on the Linux VM's own filesystem where POSIX locking works,
  # and they persist across runs so incremental deploys stay fast. Sources and the emitted
  # artifact still flow through the /workspace mount.
  docker_args=(run --rm --init --platform "$docker_platform")
  if [[ "$git_common_dir" != "$repo_root/.git" ]]; then
    docker_args+=(-v "$git_common_dir:$git_common_dir")
  fi
  docker "${docker_args[@]}" \
    -v "$repo_root:/workspace" \
    -v "$zig_cache_volume:/root/spaces-zig-cache" \
    -v "$swift_cache_volume:/root/spaces-swift-cache" \
    -e ZIG_LOCAL_CACHE_DIR=/root/spaces-zig-cache/local \
    -e ZIG_GLOBAL_CACHE_DIR=/root/spaces-zig-cache/global \
    -e SPACES_LINUX_SWIFT_BUILD_PATH=/root/spaces-swift-cache/build \
    -e SPACES_LINUX_SWIFT_CACHE_PATH=/root/spaces-swift-cache/cache \
    -e SPACES_LINUX_SWIFT_CONFIG_PATH=/root/spaces-swift-cache/config \
    -e SPACES_LINUX_SWIFT_SECURITY_PATH=/root/spaces-swift-cache/security \
    -w /workspace \
    "$builder_image" \
    bash -lc '
      set -euo pipefail
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
