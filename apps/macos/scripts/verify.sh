#!/bin/sh
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"

cd "$root"

"$root/scripts/lint.sh"
"$root/scripts/swiftpm.sh" build
"$root/scripts/coverage.sh"
