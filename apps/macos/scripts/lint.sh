#!/bin/sh
set -eu

app_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$app_root/../.." && pwd)"

echo "Formatting staged Swift files..."
"$repo_root/scripts/format-staged-swift.sh"

if command -v swiftlint >/dev/null 2>&1; then
  echo "Running SwiftLint..."
  exec swiftlint --strict --quiet "$app_root"
fi

echo "No additional Swift linter configured."
