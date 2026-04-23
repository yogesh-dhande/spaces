#!/bin/sh
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

if ! swift format --help >/dev/null 2>&1; then
  echo "swift format is required for pre-commit formatting." >&2
  exit 1
fi

staged_files="$(git diff --cached --name-only --diff-filter=ACMR | grep '^apps/macos/\(Sources\|Tests\)/.*\.swift$' || true)"

if [ -z "$staged_files" ]; then
  exit 0
fi

echo "$staged_files" | while IFS= read -r file; do
  [ -n "$file" ] || continue
  swift format format --in-place "$file"
done

echo "$staged_files" | while IFS= read -r file; do
  [ -n "$file" ] || continue
  git add -- "$file"
done
