#!/bin/sh
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
swift_paths="$root/Sources $root/Tests"

if swift format --help >/dev/null 2>&1; then
  echo "Running swift format..."
  exec swift format format --in-place --parallel --recursive $swift_paths
fi

echo "swift format is not available." >&2
exit 1
