#!/bin/sh
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_root="$repo_root/apps/macos"

exec "$app_root/scripts/lint.sh" "$@"
