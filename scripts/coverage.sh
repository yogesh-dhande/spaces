#!/bin/sh
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_root="$repo_root/apps/macos"

cd "$app_root"
exec ./scripts/coverage.sh "$@"
