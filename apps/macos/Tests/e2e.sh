#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cd "$ROOT_DIR"

"$ROOT_DIR/scripts/swiftpm.sh" build --product spacese2e
exec "$ROOT_DIR/apps/macos/.build/debug/spacese2e" e2e "$@"
