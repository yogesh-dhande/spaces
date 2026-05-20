#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR=$(cd "$(dirname "$0")/../../.." && pwd)
source "$SCRIPT_DIR/terminal_harness_lock.sh"
cd "$ROOT_DIR"

cleanup() {
  release_terminal_harness_lock
}
trap cleanup EXIT

acquire_terminal_harness_lock
export SPACES_TERMINAL_HARNESS_LOCK_HELD=1

echo "Running Ghostty mobile client E2E..."
python3 apps/macos/Tests/poc_mobile_terminal_client.py --start-app
