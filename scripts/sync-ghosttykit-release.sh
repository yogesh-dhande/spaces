#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TAG_FILE="$REPO_ROOT/apps/macos/ghosttykit-release-tag.txt"
FORK_REPO="${SPACES_GHOSTTYKIT_REPO:-yogesh-dhande/ghostty}"

if [[ ! -f "$TAG_FILE" ]]; then
    echo "Missing tag file: $TAG_FILE" >&2
    exit 1
fi

current_tag="$(tr -d '[:space:]' < "$TAG_FILE")"
latest_tag="$(gh release view --repo "$FORK_REPO" --json tagName --jq .tagName)"

if [[ -z "$latest_tag" ]]; then
    echo "Unable to resolve latest release tag for $FORK_REPO" >&2
    exit 1
fi

if [[ "$latest_tag" == "$current_tag" ]]; then
    echo "GhosttyKit release tag already current: $current_tag"
    exit 0
fi

printf '%s\n' "$latest_tag" > "$TAG_FILE"
echo "Updated GhosttyKit release tag: $current_tag -> $latest_tag"
