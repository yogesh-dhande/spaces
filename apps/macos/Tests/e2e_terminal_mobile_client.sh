#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$ROOT_DIR"

echo "Running Ghostty mobile client E2E..."
python3 apps/macos/Tests/poc_mobile_terminal_client.py --start-app
