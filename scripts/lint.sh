#!/bin/sh
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"

if swift format --help >/dev/null 2>&1; then
  echo "Running swift format lint..."
  swift format lint --recursive "$root/Sources" "$root/Tests"
  exit 0
fi

if command -v swiftlint >/dev/null 2>&1; then
  echo "Running SwiftLint..."
  swiftlint --strict --quiet "$root"
  exit 0
fi

echo "No Swift linter found. Install swift-format (preferred) or SwiftLint." >&2
exit 1
