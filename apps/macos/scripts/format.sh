#!/bin/sh
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$root/../.." && pwd)"

if swift format --help >/dev/null 2>&1; then
  echo "Running swift format..."
  exec swift format format \
    --configuration "$repo_root/.swift-format" \
    --in-place \
    --parallel \
    --recursive \
    "$@" \
    "$repo_root/apps/macos/Sources" \
    "$repo_root/apps/macos/Tests" \
    "$repo_root/apps/ios/Sources" \
    "$repo_root/apps/ios/Tests" \
    "$repo_root/apps/ios/UITests"
fi

echo "swift format is not available." >&2
exit 1
