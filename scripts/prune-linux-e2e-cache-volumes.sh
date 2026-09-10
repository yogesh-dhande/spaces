#!/usr/bin/env bash
set -euo pipefail

# apps/macos/scripts/deploy_linux_spacesd_e2e.sh keeps the Zig and SwiftPM build/cache state for
# the Linux daemon build in named Docker volumes rather than a host bind mount: lock acquisition
# over Docker Desktop's macOS file sharing deadlocks the ghostty-vt `zig build` (workers park in
# `futex_wait` with finished compile children unreaped). Named volumes live on the Docker Desktop
# Linux VM's own filesystem where POSIX locking works.
#
# The volumes are named per worktree (spaces-linux-{zig,swift}-<hash of the worktree root>) so
# concurrent worktrees never share build state. A worktree is created fresh per pull request and
# removed after merge, and nothing regenerates its hash once the worktree is gone, so the volumes
# it left behind can never be reused -- they are pure leak. This script deletes exactly those.
#
# Ownership is read from the volume's own `dev.usespaces.spaces.worktree` label, which the deploy
# script stamps with the absolute worktree path it built from, rather than from a hash inventory.
# Docker volumes are global to the daemon while `git worktree list` only ever describes one clone:
# a second Spaces clone's volumes are visible here and its worktrees are not, so a hash inventory
# alone would reclaim a live worktree's cache belonging to a clone this script cannot see.
#
# A blanket `docker volume prune` (or `-a`, or `docker system prune`) is never used here or
# anywhere else in this repository: on a machine that also runs other Docker projects, the
# unused-named volume set can include live databases that happen not to be attached to a running
# container right now. Removal is scoped by an explicit name-prefix match against
# `spaces-linux-` only, never by "unused."

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "prune-linux-e2e-cache-volumes: docker is not available; skipping." >&2
  exit 0
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# Captured before anything is examined, and its exit status checked, so an inventory that cannot be
# taken stops the run instead of yielding an empty live set -- under which every volume looks
# abandoned and the whole lane cache is deleted.
if ! worktree_inventory="$(git -C "$repo_root" worktree list --porcelain)"; then
  echo "prune-linux-e2e-cache-volumes: could not list worktrees for $repo_root; nothing pruned." >&2
  exit 1
fi

if ! volume_inventory="$(docker volume ls --format '{{.Name}}')"; then
  echo "prune-linux-e2e-cache-volumes: could not list Docker volumes; nothing pruned." >&2
  exit 1
fi

# The live set of worktree hashes for THIS clone, computed identically to how the deploy script
# names its volumes: hash the physical, resolved path (`cd ... && pwd`), not the raw
# `git worktree list` text, since the deploy script hashes its own `repo_root` the same way. Built
# as a newline-delimited list, not an associative array, because the macOS system `/bin/bash` this
# script runs under (3.2) predates `declare -A`.
live_hashes=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*)
      wt_path="${line#worktree }"
      [[ -d "$wt_path" ]] || continue
      resolved_path="$(cd "$wt_path" && pwd)"
      hash="$(printf '%s' "$resolved_path" | shasum -a 256 | awk '{print substr($1, 1, 8)}')"
      live_hashes="$live_hashes
$hash"
      ;;
  esac
done <<<"$worktree_inventory"

# Empty for a volume with no labels at all, and for one labeled by some other lane.
worktree_label_format='{{if .Labels}}{{index .Labels "dev.usespaces.spaces.worktree"}}{{end}}'

removed=()
kept=()

while IFS= read -r volume; do
  [[ -n "$volume" ]] || continue
  case "$volume" in
    spaces-linux-zig-*) hash="${volume#spaces-linux-zig-}" ;;
    spaces-linux-swift-*) hash="${volume#spaces-linux-swift-}" ;;
    *) continue ;;
  esac

  if ! labeled_worktree="$(docker volume inspect --format "$worktree_label_format" "$volume" 2>/dev/null)"; then
    kept+=("$volume (could not be inspected, not removed)")
    continue
  fi

  if [[ -n "$labeled_worktree" ]]; then
    # The volume says which worktree it belongs to, so its own label answers the question with no
    # inventory involved -- including for a worktree of a clone this script knows nothing about.
    if [[ -d "$labeled_worktree" ]]; then
      kept+=("$volume (live worktree $labeled_worktree)")
      continue
    fi
  else
    # No label: created before the deploy script started stamping one, so the hash rule against this
    # clone's worktrees is the only thing left to match it by. Residual, accepted: an unlabeled idle
    # cache belonging to a DIFFERENT clone's live worktree hashes to a path this inventory does not
    # contain and is reclaimed here. The cost is one cold rebuild of that lane, after which the
    # rebuilt volume carries a label and is matched by it; the alternative -- keeping every
    # unlabeled volume forever -- would never reclaim the leak this script exists for.
    if printf '%s\n' "$live_hashes" | grep -qx "$hash"; then
      kept+=("$volume (live worktree)")
      continue
    fi
  fi

  if docker volume rm "$volume" >/dev/null 2>&1; then
    removed+=("$volume")
  else
    # Docker refuses to remove a volume a container still has mounted. That refusal is an
    # answer, not an obstacle to work around with `-f`/`--force`: keep the volume and report it.
    kept+=("$volume (in use, not removed)")
  fi
done <<<"$volume_inventory"

# `set -u` under the macOS system bash (3.2) treats "${arr[@]}" on an empty array as an unbound
# variable, and both arrays are empty on a machine with no lane volumes at all.
for volume in ${removed[@]+"${removed[@]}"}; do
  echo "removed: $volume"
done
for volume in ${kept[@]+"${kept[@]}"}; do
  echo "kept: $volume"
done
