#!/usr/bin/env bash
set -euo pipefail

FILE="${1:?usage: open_diff.sh /path/to/file}"

# Make FILE absolute (portable)
if [[ "$FILE" = /* ]]; then
  FILE_ABS="$FILE"
else
  FILE_ABS="$(cd "$(dirname "$FILE")" && pwd -P)/$(basename "$FILE")"
fi

# Directory containing the file
FILE_DIR="$(cd "$(dirname "$FILE_ABS")" && pwd -P)"

# Find git repo root starting from the file's directory
if ! REPO_ROOT="$(git -C "$FILE_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  echo "Error: file is not inside a git repository: $FILE_ABS" >&2
  exit 2
fi

REPO_ROOT_PHYS="$(cd "$REPO_ROOT" && pwd -P)"

# Ensure file is actually inside the repo (defensive)
case "$FILE_ABS" in
  "$REPO_ROOT_PHYS"/*) ;;
  *)
    echo "Error: file is not under repo root: $FILE_ABS" >&2
    exit 2
    ;;
esac

# Repo-relative path
REL_PATH="${FILE_ABS#"$REPO_ROOT_PHYS"/}"

# If file is new/untracked, just open it normally
if ! git -C "$REPO_ROOT_PHYS" cat-file -e "HEAD:$REL_PATH" 2>/dev/null; then
  echo "Note: $REL_PATH not in HEAD (new/untracked). Opening file only."
  surf "$FILE_ABS"
  exit 0
fi

TMP="/tmp/windsurf-diff-$(git -C "$REPO_ROOT_PHYS" rev-parse --short HEAD)-$(echo "$REL_PATH" | tr '/:' '__').HEAD"

git -C "$REPO_ROOT_PHYS" show "HEAD:$REL_PATH" > "$TMP"

# Open diff: committed (left) vs working tree (right)
surf --diff "$TMP" "$FILE_ABS"
